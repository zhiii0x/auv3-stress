// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import AppKit
import AudioToolbox
import AVFoundation

// The checks, in order. Each section prints what it did; failures are bugs a host can hit,
// warnings are things worth a look that can be by design (see the README).

@MainActor func runAll() async -> Int32 {
    let skip = options.skip

    // 1 ─────────────────────────────────────────────────────────────────────────────────────────
    report.section("1. Instantiate out of process")
    guard let comp = AVAudioUnitComponentManager.shared().components(matching: options.description).first else {
        report.fail("\(options.unitCode) is not registered on this Mac (see auv3-stress --list). "
                    + "An AUv3 registers when its container app has been launched once.")
        return finish(name: "")
    }
    let unitName = "\(comp.manufacturerName): \(comp.name)"
    let isV3 = comp.audioComponentDescription.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0
    let process = isV3 ? extensionExecutable(for: options.description) : nil
    report.info("\(unitName) v\(comp.versionString), \(unitKind.label), v3: \(isV3), sandbox-safe: \(comp.isSandboxSafe)"
                + (process.map { ", extension process: \($0)" } ?? ""))
    let t0 = Date()
    let au: AUAudioUnit
    do { au = try await instantiate() } catch { report.fail("instantiate: \(error)"); return finish(name: unitName) }
    report.pass("instantiated in \(ms(since: t0)) ms, in process: \(au.isLoadedInProcess)")
    if au.isLoadedInProcess {
        report.warn("loaded in process: the rest does not exercise the out-of-process path")
    }
    let ps = parameters(au)
    // Read-only parameters (meters) are the unit's to move: not fuzzed, not expected to restore.
    let readOnly = ps.filter { !$0.flags.contains(.flag_IsWritable) }
    let checked = ps.filter { !skip.contains($0.address) && $0.flags.contains(.flag_IsWritable) }
    let paramNames = names(au)
    report.info("outputs \(au.outputBusses.count), inputs \(au.inputBusses.count), parameters \(ps.count)"
                + (skip.isEmpty ? "" : " (\(ps.filter { skip.contains($0.address) }.count) skipped)")
                + (readOnly.isEmpty ? "" : " (\(readOnly.count) read-only, left alone)")
                + ", factory presets \(au.factoryPresets?.count ?? 0), MIDI out \(au.midiOutputNames), "
                + "latency \(au.latency), tail \(au.tailTime), custom UI \(au.providesUserInterface)")
    if unitKind.playsNotes && au.scheduleMIDIEventBlock == nil {
        report.fail("a \(unitKind.label) with no MIDI input (scheduleMIDIEventBlock is nil)")
    }
    let s0 = au.fullState

    if let scenario = options.scenarioPath {
        do {
            report.section("Scenario")
            try await runScenario(au, path: scenario)
            if let png = options.snapshotPath {
                report.section("Editor")
                if let vc = await requestEditor(au) {
                    let size = options.windowSize ?? (vc.preferredContentSize == .zero ? NSSize(width: 800, height: 560) : vc.preferredContentSize)
                    let w = showWindow(vc, size: size, at: NSPoint(x: 80, y: 160), title: "auv3-stress: \(comp.name)")
                    await pause(1.5)
                    if let problem = await snapshot(w, to: png) { report.warn("no snapshot: \(problem)") }
                    else { report.info("snapshot: \(png)") }
                    closeWindow(w)
                } else {
                    report.warn("no snapshot: the unit gave no editor")
                }
            }
            au.deallocateRenderResources()
        } catch {
            let e = error as NSError
            if e.domain == "auv3-stress" { report.info("stopping here: the extension is gone") }
            else { report.fail("host setup threw: \(error)") }
        }
        report.section("Crash reports")
        await crashReportCheck(process: process, unitName: comp.name)
        return finish(name: unitName)
    }

    // 2 ─────────────────────────────────────────────────────────────────────────────────────────
    report.section("2. Parameter definitions")
    var problems: [String] = [], cosmetic: [String] = []
    var addrs = Set<AUParameterAddress>(), ids = Set<String>()
    for p in ps {
        if !addrs.insert(p.address).inserted { problems.append("duplicate address \(p.address)") }
        if !ids.insert(p.identifier).inserted { problems.append("duplicate identifier \(p.identifier)") }
        if p.displayName.isEmpty { cosmetic.append("\(p.address) has no name") }
        if !(p.minValue < p.maxValue) { problems.append("\(p.identifier) min \(p.minValue) ≥ max \(p.maxValue)") }
        if !p.value.isFinite || p.value < p.minValue || p.value > p.maxValue {
            problems.append("\(p.identifier) = \(p.value), outside \(p.minValue)…\(p.maxValue)")
        }
        if let vs = p.valueStrings, !(AUValue(vs.count) == (p.maxValue - p.minValue).rounded() + 1) {
            problems.append("\(p.identifier): \(vs.count) value strings for \(p.minValue)…\(p.maxValue)")
        }
        if !p.minValue.isFinite || !p.maxValue.isFinite { problems.append("\(p.identifier) has a range that isn't finite") }
        if !p.flags.contains(.flag_IsReadable) && !p.flags.contains(.flag_IsWritable) {
            problems.append("\(p.identifier) is neither readable nor writable")
        }
        var lo = p.minValue, hi = p.maxValue
        if p.string(fromValue: &lo).isEmpty || p.string(fromValue: &hi).isEmpty {
            cosmetic.append("\(p.identifier) has an empty display string")
        }
    }
    if ps.isEmpty { report.info("no parameters") }
    else if problems.isEmpty { report.pass("\(ps.count) parameters: unique ids/addresses, defaults in range, value strings consistent") }
    else { problems.forEach { report.fail($0) } }
    if !cosmetic.isEmpty { report.warn("hosts will show blanks: \(preview(cosmetic))") }

    do {
        // 3 ─────────────────────────────────────────────────────────────────────────────────────
        report.section("3. Sample rates × block sizes (no host transport)")
        for sr in [44100.0, 48000, 96000] {
            var bad: [String] = [], silent: [String] = []
            var peak: Float = 0
            var refused: String?
            for bs: AUAudioFrameCount in [64, 128, 256, 512, 1024] {
                let h: Host
                do { h = try Host(au, sampleRate: sr, maxFrames: 1024) } catch { refused = try refusal(error); break }
                _ = await offMain { h.run(seconds: 1, block: bs) }
                peak = max(peak, h.peak)
                if h.errorCount > 0 {
                    if deadStatuses.contains(h.firstError) { extensionDied = true }
                    bad.append("\(bs): error \(h.firstError)")
                } else if h.nonFinite > 0 { bad.append("\(bs): \(h.nonFinite) NaN/Inf") }
                else if unitKind.makesAudio && h.peak < quiet { silent.append("\(bs)") }
            }
            if let refused {
                // Every host runs at 44.1 or 48 kHz; 96 kHz can be turned down.
                (sr > 48000 ? report.warn : report.fail)("\(Int(sr)) Hz: stereo at this rate was refused (\(refused))")
            } else if !bad.isEmpty { report.fail("\(Int(sr)) Hz: \(bad.joined(separator: "; "))") }
            else if !silent.isEmpty { report.warn("\(Int(sr)) Hz: silent at block size \(silent.joined(separator: ", "))") }
            else { report.pass("\(Int(sr)) Hz, blocks 64…1024" + (unitKind.makesAudio ? ": peak \(f(peak))" : "")) }
        }

        // 4 ─────────────────────────────────────────────────────────────────────────────────────
        report.section("4. Variable block sizes and the max-frames limit")
        let hv = try Host(au, sampleRate: 48000, maxFrames: 1024)
        _ = await offMain { () -> Bool in
            for _ in 0..<2000 { if hv.render(rnd(1...1024)) != noErr { return false } }
            return true
        }
        judge(hv, "2000 buffers of 1…1024 frames")
        let over = await offMain { hv.render(1025) }
        if over == noErr { report.fail("1025 frames with maximumFramesToRender 1024 returned noErr") }
        else { report.pass("1025 frames refused (\(over))") }

        // 5 ─────────────────────────────────────────────────────────────────────────────────────
        report.section("5. Host transport, tempo and MIDI out")
        let hasMIDIOut = !au.midiOutputNames.isEmpty
        let ht = try Host(au, sampleRate: 48000, maxFrames: 512, transport: true)
        _ = await offMain { ht.run(seconds: 4, block: 256) }
        judge(ht, "4 s with the host transport moving at 120 BPM")
        let onsWhileMoving = ht.noteOns
        if hasMIDIOut { report.info("MIDI out while moving: \(ht.noteOns) note-ons, \(ht.noteOffs) note-offs") }
        ht.moving = false
        ht.playing = false
        _ = await offMain { ht.run(seconds: 1, block: 256) }
        if hasMIDIOut && onsWhileMoving > 0 {
            if ht.hangingNotes == 0 { report.pass("every note it sent was closed once the transport and the input notes stopped") }
            else { report.warn("\(ht.hangingNotes) notes left hanging after the transport and the input notes stopped") }
            if ht.noteOns != onsWhileMoving { report.info("\(ht.noteOns - onsWhileMoving) note-ons after the transport stopped") }
        }
        ht.moving = true
        ht.playing = true
        ht.resetStats()
        for t in [40.0, 300, 97.3] {
            ht.tempo = t
            _ = await offMain { ht.run(seconds: 1, block: 256) }
        }
        _ = await offMain { ht.run(seconds: 3, block: 256) { h in
            if Int(h.sampleTime / 256) % 40 == 39 { h.beat = Double(rnd(0...64) as Int) }   // cycle / locate jumps
        } }
        judge(ht, "tempo 40/300/97.3 BPM and locate jumps")
        if ht.midiOutsideBuffer > 0 {
            report.warn("\(ht.midiOutsideBuffer) MIDI-out events stamped outside the buffer they came from")
        }

        // 6 ─────────────────────────────────────────────────────────────────────────────────────
        report.section("6. Parameter fuzz")
        if checked.isEmpty {
            report.info("no parameters to fuzz")
        } else {
            let hp = try Host(au, sampleRate: 48000, maxFrames: 512)
            for _ in 0..<40 {
                for p in checked { p.setValue(randomValue(p), originator: nil) }
                _ = await offMain { hp.run(seconds: 0.05, block: 256) }
            }
            judge(hp, "40 rounds of every parameter random, rendering between", clipWarns: false, randomParameters: true)
            hp.resetStats()
            for p in checked { p.setValue(p.maxValue + 1000, originator: nil) }
            _ = await offMain { hp.run(seconds: 0.3, block: 256) }
            for p in checked { p.setValue(p.minValue - 1000, originator: nil) }
            _ = await offMain { hp.run(seconds: 0.3, block: 256) }
            // Hosts clamp what their UI sends, but scripts, MIDI learn and other plug-ins don't always.
            judge(hp, "every parameter far above max, then far below min", expectSound: false, clipWarns: false,
                  randomParameters: true)
            await pause(0.4)
            let outOfRange = checked.filter { !$0.value.isFinite || $0.value < $0.minValue || $0.value > $0.maxValue }
            if outOfRange.isEmpty { report.pass("out-of-range values clamped back into range") }
            else { report.warn("\(outOfRange.count) parameters keep an out-of-range host value: \(preview(outOfRange.map(\.identifier)))") }

            var targets: [AUParameterAddress: AUValue] = [:]
            for p in checked { let v = randomValue(p); targets[p.address] = v; p.setValue(v, originator: nil) }
            await pause(0.5)
            // A stepped parameter (%, semitones, an index) set to 73.7 reading back 74 is right;
            // 73 (truncated) or anything else is not.
            let now = values(au)
            var rounded = 0
            var readBack: [String] = []
            for (a, set) in targets.sorted(by: { $0.key < $1.key }) {
                guard let got = now[a], abs(got - set) > max(1e-4, abs(set) * 1e-4) else { continue }
                if abs(got - set.rounded()) <= 1e-4 { rounded += 1; continue }
                readBack.append("\(paramNames[a] ?? "\(a)") \(f(set))→\(f(got))")
            }
            if readBack.isEmpty {
                report.pass("every parameter reads back what the host set"
                            + (rounded > 0 ? " (\(rounded) stepped ones rounded to the nearest step)" : ""))
            } else {
                report.warn("\(readBack.count) parameters read back differently from what the host set: \(preview(readBack))")
            }
            au.fullState = s0
            await pause(0.3)
        }

        // 7 ─────────────────────────────────────────────────────────────────────────────────────
        report.section("7. Automation and MIDI in, inside render")
        let schedule = au.scheduleParameterBlock
        if !checked.isEmpty {
            let ha = try Host(au, sampleRate: 48000, maxFrames: 512)
            _ = await offMain { ha.run(seconds: 0.5, block: 256) }
            let soundedBefore = ha.peak >= quiet
            ha.resetStats()
            _ = await offMain { ha.run(seconds: 3, block: 256) { h in
                for _ in 0..<4 {
                    let p = pick(checked)!
                    let at = AUEventSampleTime(h.sampleTime) + AUEventSampleTime(rnd(0..<256) as Int)
                    schedule(at, rndBool() ? rnd(1...512) : 0, p.address, randomValue(p))
                }
            } }
            judge(ha, "3 s with parameter events and ramps every buffer", expectSound: false, clipWarns: false,
                  randomParameters: true)
            stallCheck(ha, "automation from the render thread")
            _ = await offMain { ha.run(seconds: 0.1, block: 256) }   // the last ramps run out before the state goes back
            au.fullState = s0
            await pause(0.3)
            if ha.errorCount == 0 && soundedBefore && unitKind.makesAudio {
                ha.resetStats()
                _ = await offMain { ha.run(seconds: 1, block: 256) }
                if ha.errorCount == 0 && ha.peak < quiet {
                    report.warn("silent once the automation stopped and its state was put back: the automation left it stuck")
                } else if ha.errorCount == 0 {
                    report.pass("still plays once the automation stops")
                }
            }
        }

        // Does automation that arrives as render events (scheduleParameterBlock — how hosts play
        // automation back sample-accurately) reach the sound the way a parameter-tree write does?
        // Probed with whatever looks like a gain: a linear-gain or dB unit, or "gain", "volume" or
        // "level" in the name.
        let gainWords = ["gain", "volume", "level"]
        let gains = checked.filter { p in
            p.unit == .linearGain || p.unit == .decibels
                || gainWords.contains { p.identifier.lowercased().contains($0) || p.displayName.lowercased().contains($0) }
        }
        func tailPeak(_ h: Host, _ before: ((Host) -> Void)?) async -> Float {
            _ = await offMain { h.run(seconds: 0.5, block: 256, before: before) }   // let ringing decay
            h.resetStats()
            _ = await offMain { h.run(seconds: 1, block: 256) }
            return h.peak
        }
        if unitKind.makesAudio && !gains.isEmpty {
            let hg0 = try Host(au, sampleRate: 48000, maxFrames: 512)
            for p in gains { p.setValue(p.minValue, originator: nil) }
            await pause(0.3)
            let byTree = await tailPeak(hg0, nil)
            au.fullState = s0
            await pause(0.3)
            let hg1 = try Host(au, sampleRate: 48000, maxFrames: 512)
            let sent = Flag()
            let byEvent = await tailPeak(hg1) { h in
                guard !sent.stop else { return }
                sent.stop = true
                for p in gains { schedule(AUEventSampleTime(h.sampleTime), 0, p.address, p.minValue) }
            }
            report.info("\(gains.count) gain-like parameters to their minimum (\(preview(gains.map(\.identifier), 3))): "
                        + "via the parameter tree, peak \(f(byTree)); via render events, peak \(f(byEvent))")
            if byTree >= quiet {
                report.info("the minimum doesn't silence the output, so render-event automation can't be told apart here")
            } else if byEvent >= quiet {
                report.warn("render-event (scheduled) automation is ignored; only parameter-tree writes reach the sound")
            } else {
                report.pass("automation works both as parameter-tree writes and as render events")
            }
            au.fullState = s0
            await pause(0.3)
        } else if unitKind.makesAudio {
            report.info("no gain-like parameter, so render-event automation reaching the sound isn't probed")
        }

        if let midi = au.scheduleMIDIEventBlock {
            let hm = try Host(au, sampleRate: 48000, maxFrames: 512, notes: false)
            _ = await offMain { hm.run(seconds: 3, block: 256) { h in
                for _ in 0..<3 {
                    let ch: UInt8 = rnd(0...15)
                    let bytes: [UInt8]
                    switch (rnd(0..<9) as Int) {
                    case 0, 1: bytes = [0x90 | ch, rnd(0...127), rnd(1...127)]
                    case 2: bytes = [0x80 | ch, rnd(0...127), 0]
                    case 3: bytes = [0xB0 | ch, rnd(0...127), rnd(0...127)]
                    case 4: bytes = [0xC0 | ch, rnd(0...127)]
                    case 5: bytes = [0xE0 | ch, rnd(0...127), rnd(0...127)]
                    case 6: bytes = [0xF8]
                    case 7: bytes = [pick([0xFA, 0xFB, 0xFC] as [UInt8])!]
                    default: bytes = [0xF2, rnd(0...127), rnd(0...127)]
                    }
                    let at = AUEventSampleTime(h.sampleTime) + AUEventSampleTime(rnd(0..<256) as Int)
                    bytes.withUnsafeBufferPointer { midi(at, 0, bytes.count, $0.baseAddress!) }
                }
            } }
            judge(hm, "3 s of random notes, CC, program change, pitch bend, clock, start/stop, SPP",
                  expectSound: false, clipWarns: false)
            // The fuzz leaves channel state behind that no saved state covers (CC 7 at 0 silences a
            // GM synth for good): put every channel back, the way a host's panic + reset would.
            await midiPanic(hm, midi)
            au.fullState = s0
            await pause(0.3)
        } else {
            report.info("no MIDI input (scheduleMIDIEventBlock is nil)")
        }

        // 8 ─────────────────────────────────────────────────────────────────────────────────────
        report.section("8. State")
        for p in checked { p.setValue(randomValue(p), originator: nil) }
        await pause(0.4)
        let s1 = au.fullState
        let v1 = values(au)
        for p in checked { p.setValue(randomValue(p), originator: nil) }
        await pause(0.4)
        au.fullState = s1
        await pause(0.5)
        let sameInstance = diffs(v1, values(au), names: paramNames, skip: skip)
        if sameInstance.isEmpty { report.pass("same instance: \(checked.count) randomised parameters restored exactly") }
        else { report.fail("same instance: \(sameInstance.count) parameters not restored: \(preview(sameInstance))") }
        let reread = stateDiff(s1, au.fullState)
        if reread.isEmpty { report.pass("same instance: the state reads back as it was saved") }
        else { report.warn("same instance: the state read back after restoring differs in \(preview(reread))") }

        let au2 = try await instantiate()
        _ = parameters(au2)   // a host builds its parameter tree first (UI, automation), then restores
        au2.fullState = s1
        await pause(0.5)
        let fresh = diffs(v1, values(au2), names: paramNames, skip: skip)
        let freshState = stateDiff(s1, au2.fullState)
        if freshState.isEmpty { report.pass("fresh instance: the state reads back as it was saved") }
        else { report.warn("fresh instance: the state differs in \(preview(freshState))") }
        let h2 = try Host(au2, sampleRate: 48000, maxFrames: 512)
        _ = await offMain { h2.run(seconds: 0.5, block: 256) }
        judge(h2, "fresh instance renders the restored state", expectSound: false, clipWarns: false)
        await pause(0.3)
        let freshAfterRender = diffs(v1, values(au2), names: paramNames, skip: skip)
        if fresh.isEmpty {
            report.pass("fresh instance (a reopened project): parameters match")
        } else if freshAfterRender.isEmpty {
            report.warn("fresh instance: \(fresh.count) parameters only show the restored values once render resources are allocated")
        } else {
            report.fail("fresh instance: \(freshAfterRender.count) parameters never show the restored values "
                        + "(the unit's own state does): \(preview(freshAfterRender))")
        }
        au2.deallocateRenderResources()
        au.fullState = s0
        await pause(0.3)

        if let presets = au.factoryPresets, !presets.isEmpty {
            let hf = try Host(au, sampleRate: 48000, maxFrames: 512)
            var bad: [String] = [], silent: [String] = [], slow: [String] = []
            for preset in presets {
                let loading = Date()
                au.currentPreset = preset
                if ms(since: loading) > 500 { slow.append("\(preset.name) (\(ms(since: loading)) ms)") }
                await pause(0.15)
                if au.currentPreset?.number != preset.number {
                    bad.append("\(preset.name): currentPreset reads \(au.currentPreset?.number ?? -99)")
                }
                hf.resetStats()
                _ = await offMain { hf.run(seconds: 1, block: 256) }
                if hf.errorCount > 0 || hf.nonFinite > 0 { bad.append("\(preset.name): render error/NaN") }
                else if unitKind.makesAudio && hf.peak < quiet { silent.append(preset.name) }
            }
            if !bad.isEmpty { report.fail(preview(bad, 10)) }
            else { report.pass("\(presets.count) factory presets load and read back") }
            if !silent.isEmpty { report.warn("silent with preset \(preview(silent, 10))") }
            if !slow.isEmpty { report.warn("presets that take over half a second to load: \(preview(slow, 10))") }
        } else {
            report.info("no factory presets")
        }

        // Rendering goes on for as long as the loads do (it is many times faster than real time).
        let hr = try Host(au, sampleRate: 48000, maxFrames: 512)
        _ = await offMain { hr.run(seconds: 0.3, block: 128) }   // the first render's own allocations
        hr.resetStats()
        let loading = Flag()
        async let renderedWhileRestoring = offMain { () -> Bool in
            while !loading.stop { if hr.render(128) != noErr { return false }; usleep(300) }
            return true
        }
        for i in 0..<30 {
            switch i % 3 {
            case 0: au.fullState = s1
            case 1: if let p = au.factoryPresets.flatMap(pick) { au.currentPreset = p } else { au.fullState = s0 }
            default: au.fullState = s0
            }
            await pause(0.08)
        }
        loading.stop = true
        _ = await renderedWhileRestoring
        judge(hr, "30 state/preset loads while rendering", expectSound: false, clipWarns: false)
        stallCheck(hr, "state and preset loads while rendering")

        let doc = au.fullStateForDocument
        au.fullStateForDocument = doc
        report.pass("fullStateForDocument round trip")
        au.fullState = s0
        await pause(0.3)

        // 9 ─────────────────────────────────────────────────────────────────────────────────────
        report.section("9. Threads: render, parameter writes and state reads at once")
        let hc = try Host(au, sampleRate: 48000, maxFrames: 512)
        _ = await offMain { hc.run(seconds: 0.3, block: 128) }
        hc.resetStats()
        let busy = Flag()
        async let rendered = offMain { () -> Bool in
            while !busy.stop { if hc.render(128) != noErr { return false }; usleep(300) }
            return true
        }
        // The writer draws as fast as the clock lets it: from a generator of its own, so the
        // seed still decides everything that comes after this section.
        let writerRandom = random.fork()
        async let writes = offMain { [writerRandom] () -> Int in
            var generator = writerRandom
            let end = Date().addingTimeInterval(3)
            var n = 0
            while Date() < end, let p = checked.randomElement(using: &generator) {
                p.setValue(randomValue(p, using: &generator), originator: nil)
                n += 1
                usleep(500)
            }
            return n
        }
        for _ in 0..<40 { _ = au.fullState; await pause(0.07) }
        let writeCount = await writes
        busy.stop = true
        _ = await rendered
        judge(hc, "3 s of rendering, with \(writeCount) parameter writes from another thread and 40 state reads",
              expectSound: false, clipWarns: false, randomParameters: true)
        stallCheck(hc, "parameter writes and state reads while rendering")
        au.fullState = s0
        await pause(0.3)

        // 10 ────────────────────────────────────────────────────────────────────────────────────
        report.section("10. Several instances")
        var extra: [AUAudioUnit] = []
        for _ in 0..<3 { extra.append(try await instantiate()) }
        let hosts = try ([au] + extra).map { try Host($0, sampleRate: 48000, maxFrames: 512, transport: true) }
        await withTaskGroup(of: Bool.self) { g in
            for h in hosts { g.addTask { await offMain { h.run(seconds: 2, block: 256) } } }
        }
        let allClean = hosts.allSatisfy { $0.errorCount == 0 && $0.nonFinite == 0 && ($0.peak >= quiet || !unitKind.makesAudio) }
        if allClean { report.pass("4 instances rendering on 4 threads at once, all clean") }
        else { hosts.enumerated().forEach { judge($1, "instance \($0 + 1)") } }
        extra.forEach { $0.deallocateRenderResources() }
        extra.removeAll()
        try await independenceChecks(au, names: paramNames, skip: skip, restore: s0)

        // 11 ────────────────────────────────────────────────────────────────────────────────────
        report.section("11. Open/close cycles")
        let rssBefore = residentKB(of: process)
        var times: [Int] = []
        var cycleErrors = 0
        for _ in 0..<8 {
            let t = Date()
            let x = try await instantiate()
            let h = try Host(x, sampleRate: 48000, maxFrames: 512)
            _ = await offMain { h.run(seconds: 0.2, block: 256) }
            if h.errorCount > 0 || h.nonFinite > 0 { cycleErrors += 1 }
            x.deallocateRenderResources()
            times.append(ms(since: t))
        }
        if cycleErrors == 0 {
            report.pass("8 × instantiate → allocate → render → deallocate → release (\(times.map(String.init).joined(separator: "/")) ms)")
        } else {
            report.fail("\(cycleErrors) of 8 cycles hit render errors")
        }
        var srBad: [String] = [], srSilent: [String] = [], srRefused: [String] = []
        for sr in [44100.0, 48000, 88200, 96000, 22050, 192000, 44100] {
            let h: Host
            do { h = try Host(au, sampleRate: sr, maxFrames: 512) } catch { _ = try refusal(error); srRefused.append("\(Int(sr))"); continue }
            _ = await offMain { h.run(seconds: 0.2, block: 256) }
            if h.errorCount > 0 || h.nonFinite > 0 { srBad.append("\(Int(sr))") }
            else if unitKind.makesAudio && h.peak < quiet { srSilent.append("\(Int(sr))") }
        }
        if !srRefused.isEmpty { report.info("refused at \(srRefused.joined(separator: ", ")) Hz") }
        if !srBad.isEmpty { report.fail("re-allocation broke at \(srBad.joined(separator: ", ")) Hz") }
        else { report.pass("re-allocated at 44.1/48/88.2/96/22.05/192/44.1 kHz on one instance") }
        if !srSilent.isEmpty { report.warn("silent after re-allocating at \(srSilent.joined(separator: ", ")) Hz") }
        if let a = rssBefore, let b = residentKB(of: process) { report.info("extension memory \(a / 1024) MB → \(b / 1024) MB") }

        // 12 ────────────────────────────────────────────────────────────────────────────────────
        report.section("12. Render time")
        try await renderTimeChecks(au)

        // 13 ────────────────────────────────────────────────────────────────────────────────────
        report.section("13. Channel layouts")
        try await channelLayoutChecks(au)

        // 14 ────────────────────────────────────────────────────────────────────────────────────
        report.section("14. Timeline: cycles, a day-long session, pre-roll, offline")
        try await timelineChecks(au)

        // 15 ────────────────────────────────────────────────────────────────────────────────────
        report.section("15. Tail, reset, latency and bypass")
        try await tailResetBypassChecks(au)

        // 16 ────────────────────────────────────────────────────────────────────────────────────
        report.section("16. Hostile input")
        try await hostileInputChecks(au)

        // 17 ────────────────────────────────────────────────────────────────────────────────────
        report.section("17. MIDI abuse")
        try await midiAbuseChecks(au, restore: s0)

        // 18 ────────────────────────────────────────────────────────────────────────────────────
        report.section("18. Sound: clicks on parameter jumps, pitch across sample rates")
        try await clickChecks(au, checked, restore: s0)
        try await pitchChecks(au)

        // 19 ────────────────────────────────────────────────────────────────────────────────────
        report.section("19. Editor")
        if !options.editor {
            report.info("skipped (--no-editor)")
        } else {
            try await editorChecks(au, name: comp.name)
        }

        let hAfter = try Host(au, sampleRate: 48000, maxFrames: 512)
        _ = await offMain { hAfter.run(seconds: 0.5, block: 256) }
        judge(hAfter, "still renders after the editor work")

        // 20 ────────────────────────────────────────────────────────────────────────────────────
        // Last, because it can kill the extension.
        report.section("20. Corrupted state")
        // Garbage in: an empty state, then every top-level key of the real one (but the four that
        // name the component) replaced by random bytes, by a string, and left out.
        let junk = Data((0..<256).map { _ in rnd(0...255) as UInt8 })
        var garbage: [(String, [String: Any])] = [("empty dictionary", [:])]
        let identity: Set<String> = ["type", "subtype", "manufacturer", "version"]
        for k in (s0 ?? [:]).keys.sorted() where !identity.contains(k) {
            var bytes = s0 ?? [:]; bytes[k] = junk
            var text = s0 ?? [:]; text[k] = "not what was saved"
            var gone = s0 ?? [:]; gone[k] = nil
            garbage += [("\(k) = random bytes", bytes), ("\(k) = a string", text), ("\(k) left out", gone)]
        }
        let hg = try Host(au, sampleRate: 48000, maxFrames: 512)
        var garbageBad: [String] = []
        for (label, state) in garbage.prefix(31) {
            au.fullState = state
            await pause(0.15)
            hg.resetStats()
            _ = await offMain { hg.run(seconds: 0.3, block: 256) }
            if hg.errorCount > 0 || hg.nonFinite > 0 {
                if deadStatuses.contains(hg.firstError) {
                    extensionDied = true
                    report.fail("the extension died on garbage state \"\(label)\" (a corrupted project would do the same)"
                                + (label.hasPrefix("data ") ? ". If the unit hands the state to super.fullState, AUAudioUnit's "
                                   + "parameter deserializer throws an Objective-C exception on a malformed \"data\"" : ""))
                    throw NSError(domain: "auv3-stress", code: 4099, userInfo: [NSLocalizedDescriptionKey: "extension died"])
                }
                garbageBad.append(label)
            }
        }
        if garbageBad.isEmpty { report.pass("\(min(garbage.count, 31)) garbage states (empty; keys as random bytes, strings, missing): still renders") }
        else { report.fail("render error/NaN after garbage state: \(preview(garbageBad))") }
        au.deallocateRenderResources()
    } catch {
        // A dead extension takes its XPC connection with it (NSCocoaErrorDomain 4099).
        let e = error as NSError
        if e.domain == "auv3-stress" {
            report.info("stopping here: the extension is gone")
        } else {
            if e.domain == NSCocoaErrorDomain && e.code == 4099 { extensionDied = true }
            report.fail("host setup threw: \(error)")
        }
    }

    // 21 ────────────────────────────────────────────────────────────────────────────────────────
    report.section("21. Crash reports")
    await crashReportCheck(process: process, unitName: comp.name)

    return finish(name: unitName)
}

@MainActor func editorChecks(_ au: AUAudioUnit, name: String) async throws {
    let he = try Host(au, sampleRate: 48000, maxFrames: 512, transport: true)
    _ = await offMain { he.run(seconds: 0.3, block: 256) }   // the first render's own allocations
    he.resetStats()
    let flag = Flag()
    async let editorAudio = offMain { () -> Bool in
        while !flag.stop { if he.render(256) != noErr { return false }; usleep(4000) }
        return true
    }
    guard let vc = await requestEditor(au) else {
        flag.stop = true
        _ = await editorAudio
        if au.providesUserInterface { report.fail("providesUserInterface is true but requestViewController returned nil") }
        else { report.info("no editor (providesUserInterface is false)") }
        return
    }
    report.pass("requestViewController: \(type(of: vc)), preferred size \(vc.preferredContentSize)")
    let w = showWindow(vc, size: options.windowSize ?? NSSize(width: 800, height: 560), at: NSPoint(x: 80, y: 160),
                       title: "auv3-stress: \(name)")
    await pause(1.5)
    if let png = options.snapshotPath {
        if let problem = await snapshot(w, to: png) { report.warn("no snapshot: \(problem)") }
        else { report.info("snapshot: \(png)") }
    }
    for size in [NSSize(width: 400, height: 300), NSSize(width: 1024, height: 720),
                 NSSize(width: 320, height: 480), NSSize(width: 800, height: 560)] {
        w.setContentSize(size)
        await pause(0.6)
    }
    report.pass("editor shown and resized 400×300 / 1024×720 / 320×480 while audio runs")
    flag.stop = true
    _ = await editorAudio
    judge(he, "audio while the editor was open")
    stallCheck(he, "audio while the editor opened and resized")
    let hs = try Host(au, sampleRate: 44100, maxFrames: 1024, transport: true)   // the host changes sample rate under the editor
    _ = await offMain { hs.run(seconds: 1, block: 512) }
    await pause(0.5)
    judge(hs, "sample-rate change (48 → 44.1 kHz) with the editor open")
    closeWindow(w)

    var reopenFailures = 0
    for i in 0..<5 {
        guard let vc = await requestEditor(au) else { reopenFailures += 1; continue }
        let w = showWindow(vc, size: NSSize(width: 600, height: 420), at: NSPoint(x: 100 + 20 * i, y: 200),
                           title: "auv3-stress: reopen \(i + 1)")
        await pause(0.5)
        closeWindow(w)
        await pause(0.2)
    }
    if reopenFailures == 0 { report.pass("editor closed and reopened 5 times") }
    else { report.fail("\(reopenFailures) of 5 reopenings got no view controller") }

    var more: [AUAudioUnit] = []
    for _ in 0..<2 { more.append(try await instantiate()) }
    let editorHosts = try more.map { try Host($0, sampleRate: 48000, maxFrames: 512) }
    var windows: [NSWindow] = []
    for (i, x) in ([au] + more).enumerated() {
        if let vc = await requestEditor(x) {
            windows.append(showWindow(vc, size: NSSize(width: 480, height: 360),
                                      at: NSPoint(x: 40 + 500 * i, y: 120), title: "auv3-stress: instance \(i + 1)"))
        }
    }
    await pause(2)
    windows.forEach(closeWindow)
    if windows.count == 3 { report.pass("3 instances with editors open at once") }
    else { report.fail("only \(windows.count) of 3 editors opened") }
    editorHosts.forEach { $0.au.deallocateRenderResources() }
    more.removeAll()
    await pause(0.5)
}

/// New crash reports from the extension (or the AU hosting service, for v2 units out of
/// process). macOS writes one some seconds after a process dies, so a death seen earlier waits.
@MainActor func crashReportCheck(process: String?, unitName: String) async {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
    let needles = ["AUHostingService", process, unitName.replacingOccurrences(of: " ", with: "")]
        .compactMap { $0 }.filter { !$0.isEmpty }
    func newCrashReports() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { url in
                let name = url.lastPathComponent
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                return date > started && needles.contains { name.contains($0) }
            }
    }
    var crashes = newCrashReports()
    if extensionDied && crashes.isEmpty {
        report.info("the extension died: waiting up to 60 s for its crash report…")
        for _ in 0..<60 where crashes.isEmpty { await pause(1); crashes = newCrashReports() }
        if crashes.isEmpty { report.fail("the extension died but no crash report appeared") }
    }
    if crashes.isEmpty && !extensionDied { report.pass("no crash reports (\(needles.joined(separator: ", "))) since the run started") }
    else { crashes.forEach { report.fail("crash report: ~/Library/Logs/DiagnosticReports/\($0.lastPathComponent)") } }
}

func finish(name: String) -> Int32 {
    let seconds = Int(Date().timeIntervalSince(started))
    print("\n\(report.failed ? "FAILED" : "PASSED"): \(report.fails) failed, \(report.warns) warnings"
          + (options.strict && report.warns > 0 ? " (--strict: warnings fail)" : "")
          + ", \(seconds) s, seed \(options.seed)")
    let saved = audioLog.closeAll()
    if let dir = options.audioDir { print("\(saved) WAV files in \(dir)") }
    if let path = options.jsonPath { report.writeJSON(to: path, unit: options.unitCode, name: name, seconds: seconds) }
    if let path = options.junitPath { report.writeJUnit(to: path, unit: options.unitCode, name: name, seconds: seconds) }
    return report.failed ? 1 : 0
}
