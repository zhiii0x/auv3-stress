// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import AudioToolbox
import AVFoundation
import Foundation

/// What the host puts on the input buses.
enum InputSignal {
    /// A 220 Hz sine with a little noise, −12 dB: the ordinary test signal.
    case sine
    /// White noise at −12 dB.
    case noise
    /// The sine alone at −12 dB, no noise: for hearing steps in the waveform.
    case tone
    case silence
    /// Every sample +1.
    case dc
    /// A full-scale 220 Hz square wave.
    case square
    /// The sine at +24 dB (a gain stage upstream left wide open).
    case hot
    /// One sample at 1, then silence.
    case impulse
    /// ±1e-39: numbers so small that some CPUs handle them many times slower.
    case denormal
    /// NaN, +Inf and −Inf, as a broken plug-in upstream would send.
    case nonFinite
}

/// The standard (deinterleaved float) format with this many channels. Past stereo that takes a
/// channel layout; one that only counts channels is used.
func standardFormat(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFormat {
    if channels <= 2, let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels) { return format }
    if channels > 2, let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channels) {
        return AVAudioFormat(standardFormatWithSampleRate: sampleRate, channelLayout: layout)
    }
    throw NSError(domain: "auv3-stress", code: 1, userInfo: [NSLocalizedDescriptionKey:
        "no audio format for \(channels) channels at \(sampleRate) Hz"])
}

/// A minimal host for one AU instance: formats, max frames, optional transport, a test signal on
/// every input bus, notes for instruments, and MIDI out bookkeeping.
final class Host: @unchecked Sendable {
    static let scale: [UInt8] = [48, 55, 60, 64, 67, 72]

    let au: AUAudioUnit
    let sampleRate: Double
    let maxFrames: AUAudioFrameCount
    let feedsNotes: Bool
    private let buffer: AVAudioPCMBuffer
    private let inputBuffer: AVAudioPCMBuffer?
    private let renderBlock: AURenderBlock
    private let midiIn: AUScheduleMIDIEventBlock?
    private var pullInput: AURenderPullInputBlock?

    var sampleTime: Double = 0
    var beat: Double = 0
    var tempo: Double = 120
    /// Where the transport is, relative to the render clock (`sampleTime`): a host's render
    /// timestamps keep counting while its playhead cycles, locates, or starts before zero.
    var positionOffset: Double = 0
    /// Host transport moving (only reported when `transport` was asked for).
    var moving = true
    /// Keep feeding notes; when false, the notes already sounding still get their note-offs.
    var playing = true

    /// Notes to hold down instead of the arpeggio (an empty list: no notes at all). Changing it
    /// presses and releases keys at the start of the next buffer.
    var hold: [UInt8]?
    var holdVelocity: UInt8 = 100
    private var held: [UInt8] = []
    private var recorder: WavWriter?
    private var interleaved: [Float] = []

    private var nextNoteAt: Double = 0
    private var noteIndex = 0
    private var pendingOffs: [(at: Double, key: UInt8)] = []
    private var phase: Double = 0
    private var noise = random.fork()
    private var impulseSent = false
    /// The input is made once for each render call; every bus that pulls gets the same samples.
    private var renderCount = 0, inputMadeFor = -1, inputFrames = 0

    /// What goes into the input buses.
    var input = InputSignal.sine { didSet { impulseSent = false } }
    /// Keep channel 0 of what went in (bus 0) and what came out, to compare them.
    var capture = false
    private(set) var capturedInput: [Float] = [], capturedOutput: [Float] = []

    private let lock = NSLock()
    private var openNotes = Set<UInt16>()
    private(set) var noteOns = 0, noteOffs = 0, midiOutsideBuffer = 0
    private var bufStart: Double = 0, bufFrames: Double = 0

    private(set) var peak: Float = 0
    private(set) var nonFinite = 0
    private(set) var errorCount = 0
    private(set) var firstError: OSStatus = noErr
    /// Frames rendered since the stats were reset, and where in them the output was first and
    /// last above `quiet`.
    private(set) var framesRendered = 0
    private(set) var firstSoundAt: Int?, lastSoundAt: Int?
    /// How long each render call took, as a fraction of the time its buffer lasts, and the longest.
    private(set) var loads: [Float] = []
    private(set) var worstRenderSeconds: Double = 0

    init(_ au: AUAudioUnit, sampleRate: Double = 48000, maxFrames: AUAudioFrameCount = 1024,
         transport: Bool = false, notes: Bool = unitKind.playsNotes,
         inChannels: AVAudioChannelCount? = nil, outChannels: AVAudioChannelCount? = nil,
         offline: Bool = false) throws {
        self.au = au
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        if au.renderResourcesAllocated { au.deallocateRenderResources() }

        au.isRenderingOffline = offline

        // Output: stereo if the unit takes it, else whatever channel count its bus has. A layout
        // that was asked for by name is not negotiable.
        var out = try standardFormat(sampleRate: sampleRate, channels: outChannels ?? 2)
        if au.outputBusses.count > 0 {
            do {
                try au.outputBusses[0].setFormat(out)
            } catch {
                if outChannels != nil { throw error }
                out = try standardFormat(sampleRate: sampleRate, channels: max(1, au.outputBusses[0].format.channelCount))
                try au.outputBusses[0].setFormat(out)
            }
        }
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: out, frameCapacity: maxFrames * 2) else {   // room for the too-many-frames probe
            throw NSError(domain: "auv3-stress", code: 2, userInfo: [NSLocalizedDescriptionKey: "no buffer for \(out)"])
        }
        buffer = outputBuffer

        // Inputs: the same format where accepted; every input bus gets the test signal.
        if au.inputBusses.count > 0 {
            let wanted = try inChannels.map { try standardFormat(sampleRate: sampleRate, channels: $0) } ?? out
            for i in 0..<au.inputBusses.count {
                let bus = au.inputBusses[i]
                do {
                    try bus.setFormat(wanted)
                } catch {
                    if i == 0 && inChannels != nil { throw error }
                    if let format = try? standardFormat(sampleRate: sampleRate, channels: max(1, bus.format.channelCount)) {
                        try? bus.setFormat(format)
                    }
                }
                bus.isEnabled = true
            }
            inputBuffer = AVAudioPCMBuffer(pcmFormat: au.inputBusses[0].format, frameCapacity: maxFrames * 2)
        } else {
            inputBuffer = nil
        }

        au.maximumFramesToRender = maxFrames
        renderBlock = au.renderBlock
        midiIn = au.scheduleMIDIEventBlock
        feedsNotes = notes && midiIn != nil

        if inputBuffer != nil {
            pullInput = { [weak self] _, _, frames, bus, abl in
                self?.fillInput(frames, bus, abl)
                return noErr
            }
        }
        if transport {
            au.musicalContextBlock = { [weak self] tempo, num, den, beat, toNext, downbeat in
                guard let self else { return false }
                tempo?.pointee = self.tempo
                num?.pointee = 4
                den?.pointee = 4
                beat?.pointee = self.beat
                toNext?.pointee = 0
                downbeat?.pointee = (self.beat / 4).rounded(.down) * 4
                return true
            }
            au.transportStateBlock = { [weak self] flags, pos, cycleStart, cycleEnd in
                guard let self else { return false }
                flags?.pointee = self.moving ? [.moving] : []
                pos?.pointee = self.sampleTime + self.positionOffset
                cycleStart?.pointee = 0
                cycleEnd?.pointee = 0
                return true
            }
        } else {
            au.musicalContextBlock = nil
            au.transportStateBlock = nil
        }
        au.midiOutputEventBlock = { [weak self] time, _, length, bytes in
            self?.midiOut(time, length, bytes)
            return noErr
        }
        try au.allocateRenderResources()
        recorder = audioLog.writer(sampleRate: sampleRate, channels: Int(out.channelCount))
    }

    // MARK: MIDI out

    private func midiOut(_ time: AUEventSampleTime, _ length: Int, _ b: UnsafePointer<UInt8>) {
        lock.lock(); defer { lock.unlock() }
        guard length >= 3 else { return }
        let status = b[0] & 0xF0
        let key = UInt16(b[0] & 0x0F) << 8 | UInt16(b[1])
        if status == 0x90 && b[2] > 0 { noteOns += 1; openNotes.insert(key) }
        else if status == 0x80 || status == 0x90 { noteOffs += 1; openNotes.remove(key) }
        let t = Double(time)
        if t < bufStart - 0.5 || t > bufStart + bufFrames + 0.5 { midiOutsideBuffer += 1 }
    }

    var hangingNotes: Int { lock.lock(); defer { lock.unlock() }; return openNotes.count }

    // MARK: What the host feeds in

    /// `input` (a 220 Hz sine with a little noise at −12 dB, unless a check asks for something
    /// else) on every channel of every input bus.
    private func fillInput(_ frames: AUAudioFrameCount, _ bus: Int, _ abl: UnsafeMutablePointer<AudioBufferList>) {
        guard let ib = inputBuffer, let chans = ib.floatChannelData else { return }
        let channels = Int(ib.format.channelCount)
        let step = 2 * Double.pi * 220 / sampleRate
        let fresh = inputMadeFor != renderCount
        if fresh { inputMadeFor = renderCount; inputFrames = Int(min(frames, ib.frameCapacity)) }
        let n = min(inputFrames, Int(frames))
        for k in 0..<(fresh ? n : 0) {
            let v: Float
            switch input {
            case .sine: v = Float(0.25 * sin(phase) + 0.02 * Double.random(in: -1...1, using: &noise))
            case .noise: v = Float.random(in: -0.25...0.25, using: &noise)
            case .tone: v = Float(0.25 * sin(phase))
            case .silence: v = 0
            case .dc: v = 1
            case .square: v = sin(phase) >= 0 ? 1 : -1
            case .hot: v = Float(15.85 * sin(phase))
            case .impulse: v = impulseSent ? 0 : 1; impulseSent = true
            case .denormal: v = (k % 2 == 0 ? 1 : -1) * Float.leastNonzeroMagnitude * 1000
            case .nonFinite: v = [Float.nan, .infinity, -.infinity][k % 3]
            }
            phase += step
            for c in 0..<channels { chans[c][k] = v }
        }
        phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
        if capture && fresh { capturedInput.append(contentsOf: UnsafeBufferPointer(start: chans[0], count: n)) }
        let list = UnsafeMutableAudioBufferListPointer(abl)
        for i in 0..<list.count {
            let src = chans[min(i, channels - 1)]
            if let dst = list[i].mData { dst.copyMemory(from: src, byteCount: n * MemoryLayout<Float>.size) }
            else { list[i].mData = UnsafeMutableRawPointer(src) }
            list[i].mDataByteSize = UInt32(n * MemoryLayout<Float>.size)
        }
    }

    /// A note every quarter second, 0.2 s long, walking up a chord; note-offs keep coming after
    /// `playing` goes false.
    private func scheduleNotes(_ frames: AUAudioFrameCount) {
        guard feedsNotes, let midi = midiIn else { return }
        let start = sampleTime, end = sampleTime + Double(frames)
        pendingOffs.removeAll { off in
            guard off.at < end else { return false }
            send(midi, max(start, off.at), [0x80, off.key, 0])
            return true
        }
        if let hold {
            for key in held where !hold.contains(key) { send(midi, start, [0x80, key, 0]) }
            for key in hold where !held.contains(key) { send(midi, start, [0x90, key, holdVelocity]) }
            held = hold
            nextNoteAt = end
            return
        }
        for key in held { send(midi, start, [0x80, key, 0]) }
        held = []
        guard playing else { nextNoteAt = end; return }
        while nextNoteAt < end {
            let at = max(start, nextNoteAt)
            let key = Host.scale[noteIndex % Host.scale.count]
            noteIndex += 1
            send(midi, at, [0x90, key, 100])
            pendingOffs.append((at + 0.2 * sampleRate, key))
            nextNoteAt += 0.25 * sampleRate
        }
    }

    private func send(_ midi: AUScheduleMIDIEventBlock, _ at: Double, _ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { midi(AUEventSampleTime(at), 0, bytes.count, $0.baseAddress!) }
    }

    // MARK: Rendering

    /// The render clock itself moves (a host restarting its engine, or hours into a session): the
    /// notes still sounding are closed first.
    func locate(to time: Double) {
        if let midi = midiIn {
            for off in pendingOffs {
                let bytes: [UInt8] = [0x80, off.key, 0]
                bytes.withUnsafeBufferPointer { midi(AUEventSampleTimeImmediate, 0, 3, $0.baseAddress!) }
            }
        }
        pendingOffs.removeAll()
        sampleTime = time
        nextNoteAt = time
    }

    /// The load (render time ÷ buffer time) that this fraction of the render calls stayed under.
    func load(percentile: Double) -> Double {
        guard !loads.isEmpty else { return 0 }
        let sorted = loads.sorted()
        return Double(sorted[min(sorted.count - 1, Int(Double(sorted.count) * percentile))])
    }

    func resetStats() {
        peak = 0; nonFinite = 0; errorCount = 0; firstError = noErr
        framesRendered = 0; firstSoundAt = nil; lastSoundAt = nil
        loads.removeAll(keepingCapacity: true); worstRenderSeconds = 0
        capturedInput.removeAll(keepingCapacity: true); capturedOutput.removeAll(keepingCapacity: true)
        lock.lock(); noteOns = 0; noteOffs = 0; midiOutsideBuffer = 0; lock.unlock()
    }

    @discardableResult
    func render(_ frames: AUAudioFrameCount) -> OSStatus {
        let abl = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let channels = buffer.floatChannelData!
        for i in 0..<abl.count {
            abl[i].mData = UnsafeMutableRawPointer(channels[i])   // the AU may have swapped in its own
            abl[i].mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        }
        scheduleNotes(frames)
        var ts = AudioTimeStamp()
        ts.mSampleTime = sampleTime
        ts.mFlags = .sampleTimeValid
        var flags = AudioUnitRenderActionFlags()
        lock.lock(); bufStart = sampleTime; bufFrames = Double(frames); lock.unlock()
        renderCount += 1
        let began = DispatchTime.now().uptimeNanoseconds
        let status = renderBlock(&flags, &ts, frames, 0, buffer.mutableAudioBufferList, pullInput)
        let took = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        worstRenderSeconds = max(worstRenderSeconds, took)
        loads.append(Float(took / (Double(frames) / sampleRate)))
        if status != noErr {
            errorCount += 1
            if firstError == noErr { firstError = status }
            return status
        }
        if au.outputBusses.count > 0 {
            for i in 0..<abl.count {
                guard let d = abl[i].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for k in 0..<Int(frames) {
                    let v = d[k]
                    if v.isFinite { peak = max(peak, abs(v)) } else { nonFinite += 1 }
                    if !(abs(v) < quiet) {   // sound, or not a number
                        let at = framesRendered + k
                        if firstSoundAt.map({ at < $0 }) ?? true { firstSoundAt = at }
                        if lastSoundAt.map({ at > $0 }) ?? true { lastSoundAt = at }
                    }
                }
                if capture && i == 0 { capturedOutput.append(contentsOf: UnsafeBufferPointer(start: d, count: Int(frames))) }
            }
        }
        framesRendered += Int(frames)
        if let recorder {
            let n = Int(frames), count = abl.count
            interleaved.removeAll(keepingCapacity: true)
            interleaved.reserveCapacity(n * count)
            for k in 0..<n {
                for i in 0..<count { interleaved.append(abl[i].mData?.assumingMemoryBound(to: Float.self)[k] ?? 0) }
            }
            recorder.append(interleaved)
        }
        sampleTime += Double(frames)
        if moving { beat += Double(frames) / sampleRate * tempo / 60 }
        return status
    }

    /// `seconds` of audio in `block`-frame buffers; `before` runs ahead of each buffer, on the
    /// render thread (schedule events there). Stops at the first error.
    @discardableResult
    func run(seconds: Double, block: AUAudioFrameCount, before: ((Host) -> Void)? = nil) -> Bool {
        var left = Int(seconds * sampleRate)
        while left > 0 {
            let n = AUAudioFrameCount(min(Int(block), left))
            before?(self)
            if render(n) != noErr { return false }
            left -= Int(n)
        }
        return true
    }
}

/// Below this peak (−80 dB) the output counts as silent.
let quiet: Float = 1e-4

/// Render errors fail. NaN/Inf and blow-ups fail too, unless `randomParameters` (any parameter may
/// be anywhere in its range — a +40 dB gain is allowed to be loud) where they warn. Silence where
/// sound was expected, and clipping, warn.
@discardableResult
func judge(_ h: Host, _ label: String, expectSound: Bool = unitKind.makesAudio, clipWarns: Bool = true,
           randomParameters: Bool = false) -> Bool {
    if h.errorCount > 0 {
        let died = deadStatuses.contains(h.firstError)
        if died { extensionDied = true }
        report.fail("\(label): render returned \(h.firstError) (\(h.errorCount)×)"
                    + (died ? ": the extension process died or hung" : ""))
        return false
    }
    if h.nonFinite > 0 {
        (randomParameters ? report.warn : report.fail)("\(label): \(h.nonFinite) NaN/Inf samples")
        return false
    }
    if h.peak > 16 {
        if randomParameters { report.info("\(label): peak \(f(h.peak)) (parameters at random, so loud can be right)"); return true }
        report.fail("\(label): peak \(f(h.peak)), blown up")
        return false
    }
    if expectSound && h.peak < quiet { report.warn("\(label): silent"); return true }
    if clipWarns && h.peak > 1 { report.warn("\(label): peak \(f(h.peak)) clips"); return true }
    report.pass(unitKind.makesAudio ? "\(label): peak \(f(h.peak))" : label)
    return true
}
