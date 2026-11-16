// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import AudioToolbox
import AVFoundation

// What goes wrong between a plug-in and a session rather than inside the plug-in: a parameter
// step that clicks, a second instance that isn't independent of the first, a pitch that follows
// the sample rate.

// MARK: Clicks

/// Each smoothly variable parameter jumps between a quarter and three quarters of its range while
/// a chord (or a tone, for an effect) holds, the way stepped automation does. A jump that puts an
/// edge in the waveform several times sharper than the steady sound has at either value is a click.
@MainActor func clickChecks(_ au: AUAudioUnit, _ checked: [AUParameter], restore s0: [String: Any]?) async throws {
    guard unitKind.makesAudio else { report.info("not probed for a \(unitKind.label)"); return }
    let smooth = checked.filter { !isStepped($0) && $0.minValue < $0.maxValue && $0.minValue.isFinite && $0.maxValue.isFinite }
    guard !smooth.isEmpty else { report.info("no smoothly variable parameters"); return }
    let limit = 48
    var tried = smooth
    if smooth.count > limit {
        tried = []
        var pool = smooth
        for _ in 0..<limit { tried.append(pool.remove(at: rnd(0..<pool.count))) }
    }
    let chord: [UInt8] = [48, 55, 60]
    let h = try Host(au, sampleRate: 48000, maxFrames: 512)
    h.input = .tone
    h.hold = chord
    _ = await offMain { h.run(seconds: 1, block: 256) }
    if let t = try trouble(h, "a held chord") { report.fail(t); return }
    guard h.peak >= quiet else { report.info("silent with a held chord, so clicks can't be heard"); return }
    h.capture = true

    // The stats are reset for every stretch that is measured, so trouble is noted as it happens.
    var problem: String?
    func note() throws { if let t = try trouble(h, "parameter jumps") { problem = problem ?? t } }
    /// The sharpest edge in the next stretch of audio.
    func edge(_ seconds: Double) async throws -> Float {
        try note()
        h.resetStats()
        _ = await offMain { h.run(seconds: seconds, block: 256) }
        try note()
        return sharpestEdge(h.capturedOutput)
    }
    /// A jump to `value`: the edge while it lands, and the steady edge once it has.
    func jump(_ p: AUParameter, to value: AUValue) async throws -> (landing: Float, steady: Float) {
        try note()
        h.resetStats()
        _ = await offMain { h.run(seconds: 0.02, block: 256) }
        p.setValue(value, originator: nil)
        await pause(0.03)   // the value crosses to the extension between two buffers of this stretch
        _ = await offMain { h.run(seconds: 0.2, block: 256) }
        let landing = sharpestEdge(h.capturedOutput)
        _ = await offMain { h.run(seconds: 0.2, block: 256) }
        return (landing, try await edge(0.3))
    }
    var clicks: [String] = []
    for p in tried {
        let was = p.value
        let low = p.minValue + (p.maxValue - p.minValue) * 0.25, high = p.minValue + (p.maxValue - p.minValue) * 0.75
        h.hold = []
        _ = await offMain { h.run(seconds: 0.05, block: 256) }
        h.hold = chord            // struck again for each parameter: a sound that decays is still there
        let first = try await jump(p, to: low)
        let up = try await jump(p, to: high)
        if h.errorCount > 0 { break }
        // Sharper than the steady sound on both sides of the jump, and again on the way back:
        // once could be the sound's own doing (a note starting, an LFO, a sequencer step).
        if up.landing > 4 * max(first.steady, up.steady) && up.landing > 0.02 {
            let down = try await jump(p, to: low)
            if down.landing > 4 * max(up.steady, down.steady) && down.landing > 0.02 {
                clicks.append("\(p.identifier) (a step of \(f(max(up.landing, down.landing))) between samples, "
                              + "\(f(max(first.steady, up.steady))) in the steady sound)")
            }
        }
        p.setValue(was, originator: nil)
    }
    try note()
    if let problem { report.fail(problem) }
    let scope = smooth.count > limit ? "\(limit) of \(smooth.count) smoothly variable parameters (picked by the seed)"
                                     : "\(smooth.count) smoothly variable parameters"
    if clicks.isEmpty { report.pass("\(scope) jump between ¼ and ¾ of their range without a click") }
    else { report.warn("\(clicks.count) of \(scope) click when they jump (smooth the value over a few milliseconds): \(preview(clicks, 4))") }
    h.hold = []
    _ = await offMain { h.run(seconds: 0.1, block: 256) }
    au.fullState = s0
    await pause(0.3)
}

// MARK: Two instances, independent

/// Two instances rendered side by side, buffer by buffer, as a host's graph does. What is played
/// into the second must not sound in the first, and the second's parameters are its own.
@MainActor func independenceChecks(_ au: AUAudioUnit, names: [AUParameterAddress: String], skip: Set<AUParameterAddress>,
                                   restore s0: [String: Any]?) async throws {
    let second = try await instantiate()
    let ha = try Host(au, sampleRate: 48000, maxFrames: 512), hb = try Host(second, sampleRate: 48000, maxFrames: 512)
    func both(_ seconds: Double) async {
        _ = await offMain { () -> Bool in
            for _ in 0..<Int(seconds * 48000 / 256) {
                if ha.render(256) != noErr || hb.render(256) != noErr { return false }
            }
            return true
        }
    }
    var bad: [String] = []
    func clean(_ label: String) throws -> Bool {
        let t = try [trouble(ha, "\(label), first instance"), trouble(hb, "\(label), second instance")].compactMap { $0 }
        bad += t
        return t.isEmpty
    }

    // Nothing goes into the first; the second is played.
    ha.hold = []
    ha.input = .silence
    hb.hold = []
    hb.input = .silence
    await both(1)
    ha.resetStats()
    await both(0.5)
    let quietAlone = ha.peak < quiet
    hb.hold = nil
    hb.input = .sine
    ha.resetStats()
    hb.resetStats()
    await both(1)
    if try clean("side by side") {
        if !quietAlone {
            report.info("the first instance sounds with nothing going in, so crosstalk can't be heard")
        } else if hb.peak < quiet {
            report.info("the second instance is silent, so crosstalk can't be heard")
        } else if ha.peak >= quiet {
            report.fail("what is played into the second instance sounds in the first (peak \(f(ha.peak))): "
                        + "voices, buffers or state shared between instances (a static, a singleton)")
        } else {
            report.pass("what is played into the second instance doesn't sound in the first")
        }
    }

    // The second instance's parameters are changed; the first's values and level must stay.
    ha.hold = nil
    ha.input = .sine
    await both(0.5)
    ha.resetStats()
    await both(1)
    let levelBefore = ha.peak, valuesBefore = values(au)
    for p in parameters(second) where !skip.contains(p.address) { p.setValue(randomValue(p), originator: nil) }
    await pause(0.4)
    await both(0.5)
    ha.resetStats()
    await both(1)
    if try clean("with the second instance's parameters changed") {
        let moved = diffs(valuesBefore, values(au), names: names, skip: skip)
        if !moved.isEmpty {
            report.fail("setting the second instance's parameters changed the first's: \(preview(moved))")
        } else if levelBefore >= quiet && (ha.peak < levelBefore * 0.5 || ha.peak > levelBefore * 2) {
            report.warn("setting the second instance's parameters changed the first's level: peak \(f(levelBefore)) → \(f(ha.peak))")
        } else {
            report.pass("the second instance's parameters leave the first's values and level alone")
        }
    }
    bad.forEach { report.fail($0) }
    second.deallocateRenderResources()
    au.fullState = s0
    await pause(0.3)
}

// MARK: Pitch across sample rates

/// A3 held at 44.1, 48 and 96 kHz. An instrument with a rate written into it (44100, usually)
/// plays sharp or flat everywhere else.
@MainActor func pitchChecks(_ au: AUAudioUnit) async throws {
    guard unitKind == .instrument, au.scheduleMIDIEventBlock != nil else {
        report.info("pitch across sample rates: instruments only")
        return
    }
    var heard: [(rate: Double, hz: Double)] = [], unsure: [String] = []
    for rate in [44100.0, 48000, 96000] {
        let h = try Host(au, sampleRate: rate, maxFrames: 512)
        h.hold = [57]
        _ = await offMain { h.run(seconds: 0.3, block: 256) }   // past the attack
        h.capture = true
        h.resetStats()
        _ = await offMain { h.run(seconds: 0.4, block: 256) }
        if let t = try trouble(h, "A3 at \(Int(rate)) Hz") { report.fail(t); return }
        let note = h.capturedOutput   // while it is held: the release is not part of it
        h.capture = false
        h.hold = []
        _ = await offMain { h.run(seconds: 0.1, block: 256) }
        if let p = pitch(of: note, sampleRate: rate), p.confidence >= 0.9 { heard.append((rate, p.hz)) }
        else { unsure.append("\(Int(rate)) Hz") }
    }
    guard unsure.isEmpty else {
        report.info("A3 has no clear pitch at \(unsure.joined(separator: ", ")) (noise, percussion, a chord or a sequence), "
                    + "so pitch across sample rates isn't compared")
        return
    }
    let text = heard.map { "\(String(format: "%.1f", $0.hz)) Hz at \(String(format: "%g", $0.rate / 1000)) kHz" }.joined(separator: ", ")
    let off = heard.map { cents($0.hz, from: 220) }
    if off.max()! - off.min()! > 50 {
        report.fail("the pitch of A3 depends on the sample rate: \(text) (a sample rate written into the code, "
                    + "or not read again when the host changes it)")
    } else if off.allSatisfy({ abs($0) > 25 }) {
        report.warn("A3 is \(Int(off[0].rounded())) cents from 220 Hz at every sample rate (\(text)): "
                    + "by design (a transposed or detuned default sound), or out of tune")
    } else {
        report.pass("A3 is in tune at every sample rate: \(text)")
    }
}
