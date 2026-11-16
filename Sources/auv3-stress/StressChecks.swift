// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import AudioToolbox
import AVFoundation

// The checks that go past ordinary use: how long render takes, other channel layouts, a timeline
// that jumps, loops and runs for a day, what comes out once the input stops, bypass, and audio
// and MIDI no well-behaved host would send but a real session eventually does.

/// Thrown to stop the run once the extension is gone (runAll reports and goes to the crash check).
func extensionGone() -> NSError {
    NSError(domain: "auv3-stress", code: 4099, userInfo: [NSLocalizedDescriptionKey: "extension died"])
}

/// A render error or NaN/Inf in what `h` rendered, as text; nil when it rendered clean. Throws
/// when the error says the extension has died.
func trouble(_ h: Host, _ label: String) throws -> String? {
    if h.errorCount > 0 {
        if deadStatuses.contains(h.firstError) {
            extensionDied = true
            report.fail("\(label): render returned \(h.firstError): the extension process died or hung")
            throw extensionGone()
        }
        return "\(label): render error \(h.firstError)"
    }
    return h.nonFinite > 0 ? "\(label): \(h.nonFinite) NaN/Inf samples" : nil
}

/// Why a host couldn't be set up for a format, for the report. Rethrows when the reason is that
/// the extension is gone.
func refusal(_ error: Error) throws -> String {
    let e = error as NSError
    if e.domain == NSCocoaErrorDomain && e.code == 4099 { throw error }
    return e.domain == NSOSStatusErrorDomain ? "\(e.code)" : "\(e.domain) \(e.code)"
}

/// A render call that took over 100 ms was waiting for something: a lock the state or the editor
/// holds, an allocation, the main thread. In a host that is a drop-out, or a frozen session.
func stallCheck(_ h: Host, _ what: String) {
    if h.worstRenderSeconds > 0.1 {
        report.warn("\(what): one render call took \(Int(h.worstRenderSeconds * 1000)) ms. Render is waiting on something "
                    + "(a lock shared with the state or the editor, an allocation, the main thread)")
    } else if h.load(percentile: 0.98) > 1 {
        report.warn("\(what): more than 2% of render calls outlast their buffer "
                    + "(\(pct(h.load(percentile: 0.98))) of its time at the 98th percentile): drop-outs in real time")
    } else if h.errorCount == 0 && !h.loads.isEmpty {
        report.info("\(what): render kept time (\(pct(h.load(percentile: 0.5))) of the buffer's time, "
                    + "worst call \(String(format: "%.2f", h.worstRenderSeconds * 1000)) ms)")
    }
}

/// Renders in half-second pieces until the output has been quiet for half a second, or `limit`
/// seconds have gone by. Returns how long the sound lasted, and whether it ever stopped.
func renderUntilQuiet(_ h: Host, limit: Double) async -> (rang: Double, stopped: Bool) {
    h.resetStats()
    let stopped = await offMain { () -> Bool in
        var rendered = 0.0
        // Half a second past the limit, so a sound that ends just inside it is heard to end.
        while rendered < limit + 0.5 {
            guard h.run(seconds: 0.5, block: 512) else { return true }
            rendered += 0.5
            let quietFrames = h.framesRendered - ((h.lastSoundAt ?? -1) + 1)
            if Double(quietFrames) >= 0.5 * h.sampleRate { return true }
        }
        return false
    }
    return (Double((h.lastSoundAt ?? -1) + 1) / h.sampleRate, stopped)
}

func pct(_ load: Double) -> String { load < 0.1 ? String(format: "%.1f%%", load * 100) : "\(Int((load * 100).rounded()))%" }

// MARK: Render time

/// How long render calls take against how long their buffers last, on a real-time thread asking
/// for a buffer every buffer's worth of time, as an audio device does. Measured from the host, so
/// the trip to the extension process is included.
@MainActor func renderTimeChecks(_ au: AUAudioUnit) async throws {
    for (block, seconds): (AUAudioFrameCount, Double) in [(256, 4), (64, 2)] {
        let h = try Host(au, sampleRate: 48000, maxFrames: 512)
        _ = await offMain { h.run(seconds: 0.5, block: block) }   // caches, voices, lazy allocations
        h.resetStats()
        let realtime = await onRealtimeThread(period: Double(block) / 48000) { granted -> Bool in
            _ = h.runPaced(seconds: seconds, block: block)
            return granted
        }
        if let t = try trouble(h, "\(block) frames") { report.fail(t); continue }
        let median = h.load(percentile: 0.5), high = h.load(percentile: 0.99)
        let late = h.loads.filter { $0 > 1 }.count
        let text = "\(block)-frame buffers (\(String(format: "%.2f", Double(block) / 48)) ms) in real time"
            + (realtime ? ", on a real-time thread" : " (the kernel refused a real-time thread: an ordinary one)")
            + ": render takes \(pct(median)) of the buffer's time (median), \(pct(high)) at the 99th percentile, "
            + "worst call \(String(format: "%.2f", h.worstRenderSeconds * 1000)) ms, \(late) of \(h.loads.count) late"
        if median > 1 { report.fail(text + ": too slow to play in real time at this buffer size") }
        else if high > 1 { report.warn(text + ": more than 1% of calls outlast their buffer (drop-outs)") }
        else if late > 0 { report.warn(text + ": a late call is a drop-out") }
        else if median > 0.5 { report.warn(text + ": over half the buffer's time for one instance") }
        else { report.pass(text) }
        if block == 256 {
            h.input = .silence
            h.playing = false
            _ = await offMain { h.run(seconds: 1.5, block: block) }
            h.resetStats()
            _ = await onRealtimeThread(period: Double(block) / 48000) { _ in h.runPaced(seconds: 1, block: block) }
            report.info("idle (silence in, no notes): \(pct(h.load(percentile: 0.5))) of the buffer's time")
        }
    }
}

// MARK: Channel layouts

/// Everything else renders in stereo. Here: the mono layouts the unit says it supports.
@MainActor func channelLayoutChecks(_ au: AUAudioUnit) async throws {
    guard au.outputBusses.count > 0 else { report.info("no output bus"); return }
    let hasInput = au.inputBusses.count > 0
    let caps = (au.channelCapabilities ?? []).map(\.intValue)
    let pairs = stride(from: 0, to: caps.count - 1, by: 2).map { (caps[$0], caps[$0 + 1]) }
    report.info("channelCapabilities (in, out): "
                + (pairs.isEmpty ? "none given (any layout with as many channels out as in)"
                                 : pairs.map { "(\($0.0), \($0.1))" }.joined(separator: " ")))
    // −1 is "any number"; (−1, −1) is "any number, the same in and out"; (−1, −2) is "any, and any".
    func claimed(_ i: Int, _ o: Int) -> Bool {
        if pairs.isEmpty { return !hasInput || i == o }
        return pairs.contains { a, b in
            if a == -1 && b == -1 { return !hasInput || i == o }
            if (a == -1 && b == -2) || (a == -2 && b == -1) { return true }
            return (a < 0 || a == i || !hasInput) && (b < 0 || b == o)
        }
    }
    let candidates = hasInput ? [(1, 1), (1, 2), (2, 1)] : [(0, 1)]
    var clean: [String] = [], bad: [String] = [], silent: [String] = []
    for (i, o) in candidates where claimed(i, o) {
        let name = hasInput ? "\(i) in → \(o) out" : "\(o) out"
        let h: Host
        do {
            h = try Host(au, sampleRate: 48000, maxFrames: 512,
                         inChannels: hasInput ? AVAudioChannelCount(i) : nil, outChannels: AVAudioChannelCount(o))
        } catch {
            if pairs.isEmpty { report.info("\(name): refused (\((error as NSError).code))") }
            else { bad.append("\(name) is in channelCapabilities but was refused (\((error as NSError).code))") }
            continue
        }
        _ = await offMain { h.run(seconds: 0.5, block: 256) }
        if let t = try trouble(h, name) { bad.append(t) }
        else if unitKind.makesAudio && h.peak < quiet { silent.append(name) }
        else { clean.append(name) }
    }
    bad.forEach { report.fail($0) }
    if !silent.isEmpty { report.warn("silent in the layout \(silent.joined(separator: ", "))") }
    if !clean.isEmpty { report.pass("renders in the layouts \(clean.joined(separator: ", "))") }
    if clean.isEmpty && bad.isEmpty && silent.isEmpty { report.info("no mono layout to try: stereo only") }
}

// MARK: Timeline

/// The playhead cycling and starting before zero, the render clock restarting, a session that has
/// been open for a day, and an offline bounce.
@MainActor func timelineChecks(_ au: AUAudioUnit) async throws {
    let h = try Host(au, sampleRate: 48000, maxFrames: 512, transport: true)
    _ = await offMain { h.run(seconds: 0.5, block: 256) }
    let usual = h.peak

    // A cycle: the playhead goes back to the start of the loop; render timestamps count on.
    _ = await offMain { () -> Bool in
        for _ in 0..<20 {
            h.positionOffset = -h.sampleTime
            h.beat = 0
            if !h.run(seconds: 0.05, block: 256) { return false }
        }
        return true
    }
    judge(h, "a 50 ms cycle, 20 times round")

    // Count-in and pre-roll: the playhead starts before zero.
    h.positionOffset = -h.sampleTime - 24000
    h.beat = -1
    h.resetStats()
    _ = await offMain { h.run(seconds: 1, block: 256) }
    judge(h, "pre-roll: the playhead and the beat start below zero and pass through it")
    h.positionOffset = 0

    // The render clock starts again from zero under an allocated unit (a host restarting its engine).
    h.resetStats()
    _ = await offMain { () -> Bool in
        for _ in 0..<5 {
            h.locate(to: 0)
            if !h.run(seconds: 0.2, block: 256) { return false }
        }
        return true
    }
    judge(h, "the render clock restarting from zero, 5 times")

    // A counter of samples kept in 32 bits wraps here.
    for (edge, name) in [(2_147_483_648.0, "2³¹ samples (12.4 h of rendering at 48 kHz)"), (4_294_967_296.0, "2³² samples (24.9 h)")] {
        h.locate(to: edge - 12000)
        h.resetStats()
        _ = await offMain { h.run(seconds: 0.5, block: 256) }   // across the edge
        if let t = try trouble(h, "crossing \(name)") { report.fail(t); continue }
        h.resetStats()
        _ = await offMain { h.run(seconds: 0.5, block: 256) }
        if h.errorCount == 0 && h.nonFinite == 0 && h.peak >= quiet && h.peak < usual * 0.1 {
            report.warn("the render clock past \(name): peak \(f(h.peak)), where it was \(f(usual)) at the start "
                        + "(sample times kept in 32 bits or in a Float lose notes and events out here)")
        } else {
            judge(h, "the render clock past \(name)")
        }
    }

    let ho = try Host(au, sampleRate: 48000, maxFrames: 4096, offline: true)
    _ = await offMain { ho.run(seconds: 3, block: 4096) }
    judge(ho, "offline bounce (isRenderingOffline, 4096-frame buffers)")
    au.deallocateRenderResources()
    au.isRenderingOffline = false
}

// MARK: Tail, reset, latency, bypass

@MainActor func tailResetBypassChecks(_ au: AUAudioUnit) async throws {
    let sr = 48000.0
    let tail = au.tailTime, latency = au.latency
    if !latency.isFinite || latency < 0 { report.fail("latency is \(latency)") }
    if tail.isNaN || tail < 0 { report.fail("tailTime is \(tail)") }
    guard unitKind.makesAudio, unitKind != .generator, unitKind != .other else {
        report.info("not probed for a \(unitKind.label)")
        return
    }
    let isEffect = au.inputBusses.count > 0
    let h = try Host(au, sampleRate: sr, maxFrames: 512)
    _ = await offMain { h.run(seconds: 1, block: 256) }
    if let t = try trouble(h, "render") { report.fail(t); return }
    let sounded = h.peak >= quiet

    // What comes out once the input and the notes have stopped.
    var goesQuiet = false
    if sounded {
        h.input = .silence
        h.playing = false
        // With notes, the last one is still held for a quarter of a second; the tail starts after it.
        if h.feedsNotes { _ = await offMain { h.run(seconds: 0.25, block: 256) } }
        let reported = tail.isFinite ? max(tail, 0) : .infinity
        let limit = isEffect ? min(reported + 2, 30) : 10
        let (rang, stopped) = await renderUntilQuiet(h, limit: limit)
        if let t = try trouble(h, "after the input stopped") { report.fail(t); return }
        goesQuiet = stopped
        let tailText = "tailTime \(tail.isFinite ? String(format: "%.2f", tail) : "\(tail)") s"
        if !stopped && reported + 2 > limit {
            report.info("still sounding \(Int(limit)) s after the input stopped, within its \(tailText)")
        } else if !stopped {
            report.warn("still sounding \(Int(limit)) s after the input and the notes stopped (\(tailText))"
                        + (isEffect ? "" : ": a drone, a very long release, or a stuck voice"))
        } else if isEffect && rang > reported + latency + 0.1 {
            report.warn("rings for \(String(format: "%.2f", rang)) s after its input stops but reports \(tailText): "
                        + "hosts stop rendering, or end a bounce, after the reported tail")
        } else {
            report.pass("quiet \(String(format: "%.2f", rang)) s after the input and the notes stop (\(tailText))")
        }
    } else {
        report.info("silent, so the tail and reset() can't be judged")
    }

    // reset(): hosts call it on stop and locate, expecting delay lines, filters and voices cleared.
    if goesQuiet {
        h.input = .sine
        h.playing = true
        _ = await offMain { h.run(seconds: 0.6, block: 256) }
        h.input = .silence
        h.playing = false
        h.locate(to: h.sampleTime)   // the held note is released, then the reset: nothing should be left sounding
        au.reset()
        h.resetStats()
        _ = await offMain { h.run(seconds: 0.2, block: 256) }
        if let t = try trouble(h, "after reset()") { report.fail(t) }
        else if h.peak >= quiet {
            report.warn("still sounding after reset() (peak \(f(h.peak))): what was in its delay lines, filters or voices "
                        + "plays on after the host stops or locates")
        } else { report.pass("reset() leaves nothing sounding") }
    }

    guard isEffect else { return }

    // Latency: when an impulse comes out, next to what the unit reports (information: a delay or
    // a wet-only reverb is late by design; hosts compensate by the reported number).
    au.reset()
    h.playing = false
    h.input = .impulse
    h.resetStats()
    h.capture = true
    _ = await offMain { h.run(seconds: min(latency.isFinite ? latency : 0, 2) + 0.5, block: 256) }
    h.capture = false
    let reportedSamples = Int((latency.isFinite ? min(max(latency, 0), 3600) : 0) * sr + 0.5)
    let response = h.capturedOutput
    let strongest = response.indices.max { abs(response[$0]) < abs(response[$1]) }
    report.info("reports a latency of \(reportedSamples) samples; an impulse first comes out after "
                + (h.firstSoundAt.map { "\($0) samples" } ?? "more than \(h.framesRendered) samples (nothing came out)"))
    // A strong arrival is the direct sound; echoes and reverb are weaker. Hosts shift the track
    // by the reported latency, so the direct sound should be there.
    if let strongest, abs(response[strongest]) >= 0.25, abs(strongest - reportedSamples) > 32 {
        report.warn("the direct sound of an impulse arrives after \(strongest) samples (peak \(f(abs(response[strongest])))) "
                    + "but the reported latency is \(reportedSamples): hosts align the track by the reported number")
    }

    // Bypass: the input should come out untouched, at no delay or at the reported latency.
    guard unitKind == .effect || unitKind == .musicEffect else { return }
    h.input = .tone
    h.capture = true
    _ = await offMain { h.run(seconds: 1, block: 256) }
    h.resetStats()
    _ = await offMain { h.run(seconds: 0.3, block: 256) }
    let edgeBefore = sharpestEdge(h.capturedOutput)
    au.shouldBypassEffect = true
    await pause(0.3)
    guard au.shouldBypassEffect else {
        report.info("shouldBypassEffect doesn't stay on: no bypass of its own (hosts bypass it themselves)")
        return
    }
    // No reset here: the switch lands between two buffers, and that join has to be in the capture.
    _ = await offMain { h.run(seconds: 0.5, block: 256) }   // the switch, and any crossfade into bypass
    let edgeSwitching = sharpestEdge(h.capturedOutput)
    h.resetStats()
    _ = await offMain { h.run(seconds: 0.5, block: 256) }
    h.capture = false
    let input = h.capturedInput, output = h.capturedOutput
    let edgeAfter = sharpestEdge(output)
    if edgeSwitching > 4 * max(edgeBefore, edgeAfter) && edgeSwitching > 0.02 {
        report.warn("switching bypass on clicks: a step of \(f(edgeSwitching)) between samples, "
                    + "\(f(max(edgeBefore, edgeAfter))) in the steady sound either side (crossfade into bypass)")
    }
    if let t = try trouble(h, "bypassed") {
        report.fail(t)
    } else {
        func difference(lag: Int) -> Float {
            guard lag < min(input.count, output.count) else { return .infinity }
            var worst: Float = 0
            for n in lag..<min(input.count + lag, output.count) { worst = max(worst, abs(output[n] - input[n - lag])) }
            return worst
        }
        let straight = difference(lag: 0), delayed = reportedSamples > 0 ? difference(lag: reportedSamples) : .infinity
        if min(straight, delayed) <= 0.01 {
            report.pass("bypassed, the input comes out untouched" + (delayed < straight ? ", delayed by the reported latency" : ""))
        } else {
            report.warn("bypassed (shouldBypassEffect), the output differs from the input by up to \(f(min(straight, delayed))) "
                        + "(the input peaks at 0.27)")
        }
    }
    au.shouldBypassEffect = false
    await pause(0.3)
    h.resetStats()
    _ = await offMain { h.run(seconds: 0.3, block: 256) }
    if let t = try trouble(h, "after bypass was switched off") { report.fail(t) }
}

// MARK: Hostile input

/// Audio no mixer is supposed to send, and every session eventually does: DC, full scale, far
/// over full scale, denormals, and NaN/Inf from a broken plug-in upstream.
@MainActor func hostileInputChecks(_ au: AUAudioUnit) async throws {
    guard au.inputBusses.count > 0 else { report.info("no audio input"); return }
    let h = try Host(au, sampleRate: 48000, maxFrames: 512)
    _ = await offMain { h.run(seconds: 0.5, block: 256) }
    h.resetStats()
    _ = await offMain { h.run(seconds: 0.5, block: 256) }
    let ordinary = h.load(percentile: 0.5)

    let signals: [(InputSignal, String)] = [(.silence, "silence"), (.dc, "DC at +1"), (.square, "a full-scale square wave"),
                                            (.hot, "a sine at +24 dB"), (.impulse, "a single impulse"), (.denormal, "denormals")]
    var bad: [String] = [], peaks: [String] = []
    var denormal = 0.0
    for (signal, name) in signals {
        au.reset()   // each on its own, not on the last one's echoes
        h.input = signal
        h.resetStats()
        _ = await offMain { h.run(seconds: 0.5, block: 256) }
        if let t = try trouble(h, name) { bad.append(t) } else { peaks.append("\(name) → \(f(h.peak))") }
        if signal == .denormal { denormal = h.load(percentile: 0.5) }
    }
    if bad.isEmpty { report.pass("input and the peak that came out: \(peaks.joined(separator: ", "))") }
    else { bad.forEach { report.fail($0) } }
    if denormal > 3 * ordinary && denormal > 0.2 {
        report.warn("denormal input makes render \(String(format: "%.1f", denormal / ordinary))× slower "
                    + "(\(pct(ordinary)) → \(pct(denormal)) of the buffer's time): set flush-to-zero in render")
    }

    // One bad buffer from upstream. NaN while it lasts is fair; NaN for ever after is a track
    // that stays dead until the project is reopened.
    h.input = .nonFinite
    _ = await offMain { h.run(seconds: 0.1, block: 256) }
    _ = try trouble(h, "NaN/Inf input")
    h.input = .sine
    _ = await offMain { h.run(seconds: 0.5, block: 256) }
    h.resetStats()
    _ = await offMain { h.run(seconds: 0.5, block: 256) }
    if h.errorCount > 0 {
        if let t = try trouble(h, "after NaN/Inf input") { report.fail(t) }
    } else if h.nonFinite == 0 {
        report.pass("0.1 s of NaN/Inf input: clean again once the input is")
    } else {
        au.reset()
        h.resetStats()
        _ = await offMain { h.run(seconds: 0.5, block: 256) }
        if h.nonFinite > 0 || h.errorCount > 0 {
            report.fail("0.1 s of NaN/Inf input: the output is still NaN/Inf a second later, and after reset() "
                        + "(the track stays dead until render resources are reallocated)")
        } else {
            report.warn("0.1 s of NaN/Inf input: the output stays NaN/Inf until the host calls reset() "
                        + "(it is kept in a delay line or a filter: sanitise the input, or clear state that isn't finite)")
        }
    }
    au.reset()
}

// MARK: MIDI abuse

/// What a host's panic and reset would send: every channel back to a known state.
func midiPanic(_ h: Host, _ midi: @escaping AUScheduleMIDIEventBlock) async {
    let sent = Flag()
    _ = await offMain { h.run(seconds: 0.1, block: 256) { h in
        guard !sent.stop else { return }
        sent.stop = true
        let at = AUEventSampleTime(h.sampleTime)
        for ch in UInt8(0)...15 {
            let messages: [[UInt8]] = [
                [0xB0 | ch, 120, 0], [0xB0 | ch, 121, 0], [0xB0 | ch, 123, 0],   // sound off, reset controllers, notes off
                [0xB0 | ch, 7, 100], [0xB0 | ch, 11, 127], [0xB0 | ch, 10, 64],  // volume, expression, pan
                [0xB0 | ch, 0, 0], [0xB0 | ch, 32, 0], [0xC0 | ch, 0],          // bank 0, program 0
                [0xE0 | ch, 0, 64],                                              // pitch bend centre
            ]
            for m in messages { m.withUnsafeBufferPointer { midi(at, 0, m.count, $0.baseAddress!) } }
        }
    } }
}

/// MIDI past what the fuzz in section 7 sends (which is all well formed): far too many notes,
/// notes that don't pair up, SysEx, messages cut short or out of spec, timestamps that are
/// immediate or already past, and cables other than 0.
@MainActor func midiAbuseChecks(_ au: AUAudioUnit, restore s0: [String: Any]?) async throws {
    guard let midi = au.scheduleMIDIEventBlock else { report.info("no MIDI input"); return }
    let h = try Host(au, sampleRate: 48000, maxFrames: 512, notes: false)
    typealias Send = (AUEventSampleTime, [UInt8], UInt8) -> Void
    let send: Send = { at, bytes, cable in
        guard !bytes.isEmpty else { return }
        bytes.withUnsafeBufferPointer { midi(at, cable, bytes.count, $0.baseAddress!) }
    }
    /// Renders `seconds`; `events` runs once, on the render thread, ahead of the first buffer.
    func stage(_ seconds: Double, _ events: @escaping (AUEventSampleTime, Send) -> Void) async {
        let sent = Flag()
        _ = await offMain { h.run(seconds: seconds, block: 256) { h in
            guard !sent.stop else { return }
            sent.stop = true
            events(AUEventSampleTime(h.sampleTime), send)
        } }
    }
    /// How loud it plays the host's usual notes, after a panic, on a clean set of stats.
    func level() async -> Float {
        await midiPanic(h, midi)
        h.resetStats()
        await stage(0.4) { t, send in for key in Host.scale { send(t, [0x90, key, 100], 0) } }
        let peak = h.peak
        await stage(0.2) { t, send in for key in Host.scale { send(t, [0x80, key, 0], 0) } }
        return peak
    }
    // An instrument that is 20 dB down after a stage has lost its notes (or its level) to it.
    let quietWithoutNotes = unitKind == .instrument ? await renderUntilQuiet(h, limit: 3).stopped : false
    let before = unitKind == .instrument ? await level() : 0
    let playedBefore = before >= quiet
    var bad: [String] = [], silenced: String?
    func check(_ name: String) async throws {
        if let t = try trouble(h, name) { bad.append(t) }
        h.resetStats()
        if playedBefore && silenced == nil {
            let now = await level()
            if now < before * 0.1 { silenced = "\(name) (peak \(f(before)) → \(f(now)))" }
        }
    }

    await stage(0.5) { t, send in
        for ch in UInt8(0)..<4 { for key in UInt8(0)...127 { send(t, [0x90 | ch, key, 100], 0) } }
    }
    await stage(0.3) { t, send in
        for ch in UInt8(0)..<4 { for key in UInt8(0)...127 { send(t, [0x80 | ch, key, 0], 0) } }
    }
    try await check("512 notes at once")

    await stage(0.3) { t, send in
        for _ in 0..<200 { send(t, [0x90, 60, 100], 0) }                                   // one key, 200 times, never released
        for ch in UInt8(0)...15 { for key in UInt8(100)...110 { send(t, [0x80 | ch, key, 64], 0) } }   // released, never played
        send(t, [0x80, 60, 0], 0)
    }
    try await check("notes that don't pair up")

    let body = (0..<1000).map { _ in rnd(0...127) as UInt8 }
    await stage(0.3) { t, send in
        send(t, [0xF0, 0x7D, 0x01, 0xF7], 0)
        send(t, [0xF0, 0x7D] + body.prefix(64) + [0xF7], 0)
        send(t, [0xF0, 0x7D] + body + [0xF7], 0)
        send(t + 64, [0xF0, 0x7D] + body.prefix(32), 0)   // never terminated
        send(t + 128, [0xF7], 0)                          // an end with no start
    }
    try await check("SysEx")

    let broken: [[UInt8]] = [[0x90], [0x90, 60], [0xB0, 7], [0xE0], [0x90, 200, 255], [0xB0, 0x80, 0x80], [0x40], [0x40, 0x40],
                             [0xF1], [0xF3], [0xF4], [0xF5], [0xF6], [0xF9], [0xFD], [0xFE], [0xFF], [0x90, 60, 100, 60, 0]]
    let order = (0..<60).map { _ in rnd(0..<broken.count) as Int }
    await stage(0.5) { t, send in
        for (n, i) in order.enumerated() { send(t + AUEventSampleTime(n * 4), broken[i], 0) }
    }
    try await check("messages cut short or out of spec")

    await stage(0.5) { t, send in
        send(AUEventSampleTimeImmediate, [0x90, 64, 100], 0)
        send(AUEventSampleTimeImmediate + 100, [0x80, 64, 0], 0)
        send(t - 100_000, [0x90, 67, 100], 0)   // stamped in the past
        send(t - 1, [0x80, 67, 0], 0)
        send(t + 255, [0xB0, 1, 64], 0)         // the last frame of the buffer
        for cable in UInt8(1)...15 { send(t, [0x90, 72, 100], cable); send(t + 200, [0x80, 72, 0], cable) }
    }
    try await check("immediate and late timestamps, cables 1–15")

    if bad.isEmpty {
        report.pass("512 notes at once, notes that don't pair up, SysEx (1 kB, unterminated), messages cut short or "
                    + "out of spec, immediate and late timestamps, cables 1–15: still renders")
    } else { bad.forEach { report.fail($0) } }

    await midiPanic(h, midi)
    if let silenced {
        au.fullState = s0
        await pause(0.3)
        let back = await level() >= before * 0.1
        report.fail("no longer plays its notes after \(silenced), not even after All Sound Off and a controller reset"
                    + (back ? "; restoring its state brings it back" : ", nor after its state is restored"))
    } else if playedBefore {
        report.pass("still plays notes after each of them")
    }
    if quietWithoutNotes && silenced == nil {
        let (_, stopped) = await renderUntilQuiet(h, limit: 10)
        if let t = try trouble(h, "after the MIDI abuse") { report.fail(t) }
        else if stopped { report.pass("quiet again once every note is released and All Sound Off is sent") }
        else { report.warn("still sounding 10 s after every note was released and All Sound Off / All Notes Off were sent: stuck voices?") }
    }
    au.fullState = s0
    await pause(0.3)
    _ = await offMain { h.run(seconds: 1, block: 256) }   // a unit that reloads samples for a state needs a moment
}
