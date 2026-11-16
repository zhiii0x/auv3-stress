// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import AppKit
import AudioToolbox
import AVFoundation

// A scenario plays the unit step by step, as someone trying it would (notes, parameter changes,
// sweeps), then says what each step sounded like and whether that is what the step expected.
//
//   { "name": "Filter and delay",
//     "steps": [
//       { "play": [48, 55, 60], "for": 2, "expect": "sound" },
//       { "sweep": "cutoff", "from": 200, "to": 8000, "over": 4, "expect": "no-click" },
//       { "set": "delayWet", "to": "50%", "for": 2 },
//       { "release": "all", "for": 3, "expect": "silence" },
//       { "play": 57, "for": 2, "expect": "in-tune" } ] }

private func number(_ any: Any?) -> Double? { (any as? NSNumber)?.doubleValue }

private func notes(_ any: Any?) -> [UInt8]? {
    if let n = number(any), (0...127).contains(n) { return [UInt8(n)] }
    if let list = any as? [Any] {
        let keys = list.compactMap { number($0) }.filter { (0...127).contains($0) }.map { UInt8($0) }
        return keys.count == list.count ? keys : nil
    }
    return nil
}

/// A parameter by identifier, by display name (case doesn't matter), or by address.
private func parameter(_ name: String, in all: [AUParameter]) -> AUParameter? {
    all.first { $0.identifier == name }
        ?? all.first { $0.identifier.lowercased() == name.lowercased() || $0.displayName.lowercased() == name.lowercased() }
        ?? AUParameterAddress(name).flatMap { address in all.first { $0.address == address } }
}

/// 0.5, or "50%" of the parameter's range.
private func value(_ any: Any?, for p: AUParameter) -> AUValue? {
    if let n = number(any) { return AUValue(n) }
    guard let text = any as? String, text.hasSuffix("%"), let percent = Double(text.dropLast()) else { return nil }
    return p.minValue + (p.maxValue - p.minValue) * AUValue(percent / 100)
}

private func noteName(_ key: UInt8) -> String {
    ["C", "C♯", "D", "D♯", "E", "F", "F♯", "G", "G♯", "A", "A♯", "B"][Int(key) % 12] + "\(Int(key) / 12 - 1)"
}

@MainActor func runScenario(_ au: AUAudioUnit, path: String) async throws {
    guard let data = FileManager.default.contents(atPath: path) else {
        report.fail("can't read \(path)")
        return
    }
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let steps = root["steps"] as? [[String: Any]], !steps.isEmpty else {
        report.fail("\(path) isn't a scenario: a JSON object with a \"steps\" array is expected")
        return
    }
    let rate = number(root["sampleRate"]) ?? 48000
    guard (8000...384000).contains(rate) else {
        report.fail("\"sampleRate\" is \(rate): 8000 to 384000 is expected")
        return
    }
    report.info("\(root["name"] as? String ?? (path as NSString).lastPathComponent): \(steps.count) steps at \(Int(rate)) Hz")
    let all = parameters(au)
    let schedule = au.scheduleParameterBlock
    let h = try Host(au, sampleRate: rate, maxFrames: 512, transport: true)
    h.hold = []
    h.input = .tone
    h.capture = true
    var held: [UInt8] = []
    var recording: [Float] = [], marks: [(at: Int, label: String)] = []
    var steadyEdge: Float = 0   // the sharpest edge of the step before, for "no-click"

    for (index, step) in steps.enumerated() {
        var label = "", seconds = 1.0
        var before: ((Host) -> Void)?
        if let keys = notes(step["play"]) {
            held += keys.filter { !held.contains($0) }
            h.holdVelocity = number(step["velocity"]).flatMap { (1...127).contains($0) ? UInt8($0) : nil } ?? 100
            seconds = number(step["for"]) ?? 2
            label = "play \(keys.map(noteName).joined(separator: " "))"
        } else if let release = step["release"] {
            if let keys = notes(release) { held.removeAll { keys.contains($0) } } else { held = [] }
            seconds = number(step["for"]) ?? 2
            label = "release \(notes(release).map { $0.map(noteName).joined(separator: " ") } ?? "all")"
        } else if let name = step["set"] as? String {
            guard let p = parameter(name, in: all), let v = value(step["to"], for: p) else {
                report.fail("step \(index + 1): no parameter \"\(name)\", or no value in \"to\"")
                continue
            }
            p.setValue(v, originator: nil)
            await pause(0.03)
            seconds = number(step["for"]) ?? 1
            label = "set \(p.identifier) to \(f(v))"
        } else if let name = step["sweep"] as? String {
            guard let p = parameter(name, in: all), let from = value(step["from"], for: p), let to = value(step["to"], for: p) else {
                report.fail("step \(index + 1): no parameter \"\(name)\", or no \"from\" and \"to\"")
                continue
            }
            seconds = number(step["over"]) ?? 4
            let total = seconds * rate
            // A frequency sweeps evenly in pitch; anything else, evenly in value.
            let inPitch = p.unit == .hertz && from > 0 && to > 0
            let address = p.address
            before = { h in
                let t = AUValue(min(1, Double(h.framesRendered) / total))
                schedule(AUEventSampleTime(h.sampleTime), 0, address, inPitch ? from * pow(to / from, t) : from + (to - from) * t)
            }
            label = "sweep \(p.identifier) \(f(from)) → \(f(to))"
        } else if let wait = number(step["wait"]) {
            seconds = wait
            label = "wait"
        } else {
            report.fail("step \(index + 1): one of play, release, set, sweep or wait is expected")
            continue
        }
        switch step["input"] as? String {
        case "silence": h.input = .silence
        case "tone": h.input = .tone
        case "noise": h.input = .noise
        case "impulse": h.input = .impulse
        default: break
        }
        guard (0...3600).contains(seconds) else {
            report.fail("step \(index + 1): \(seconds) s isn't a length (0 to 3600 is expected)")
            continue
        }
        label = "\(index + 1). \(label), \(String(format: "%g", seconds)) s"
        h.hold = held
        h.resetStats()
        _ = await offMain { h.run(seconds: seconds, block: 256, before: before) }
        let audio = h.capturedOutput
        marks.append((recording.count, label))
        recording += audio
        if let t = try trouble(h, label) { report.fail(t); continue }

        let edge = sharpestEdge(audio)
        let wanted = (step["expect"] as? [String]) ?? (step["expect"] as? String).map { [$0] } ?? []
        var failed: [String] = [], uncertain: [String] = []
        for expectation in wanted {
            switch expectation {
            case "sound":
                if h.peak < quiet { failed.append("silent, where sound was expected") }
            case "silence":
                // By the end of the step: the tail is allowed its time.
                let last = audio.suffix(max(1, audio.count / 5)).map { abs($0) }.max() ?? 0
                if last >= quiet { failed.append("still sounding at the end (peak \(f(last)) in the last fifth), where silence was expected") }
            case "in-tune":
                guard let key = held.min() else { uncertain.append("in-tune needs a note held"); break }
                let target = 440 * pow(2, (Double(key) - 69) / 12)
                guard let p = pitch(of: audio, sampleRate: rate), p.confidence >= 0.9 else {
                    uncertain.append("no clear pitch to judge the tuning by")
                    break
                }
                let off = cents(p.hz, from: target)
                if abs(off) > 25 { failed.append("\(noteName(key)) sounds at \(String(format: "%.1f", p.hz)) Hz, \(Int(off.rounded())) cents from \(String(format: "%.1f", target)) Hz") }
            case "no-click":
                if steadyEdge <= 0 {
                    uncertain.append("no-click compares with the step before, and that one was silent or isn't there")
                } else if edge > 4 * steadyEdge && edge > 0.02 {
                    failed.append("a step of \(f(edge)) between samples, where the step before had \(f(steadyEdge)) at most")
                }
            default:
                uncertain.append("\"\(expectation)\" isn't an expectation (sound, silence, in-tune, no-click)")
            }
        }
        steadyEdge = h.peak >= quiet ? edge : 0
        let heard = "peak \(f(h.peak))"
        if !failed.isEmpty { report.fail("\(label): \(failed.joined(separator: "; "))") }
        else if !uncertain.isEmpty { report.warn("\(label): \(uncertain.joined(separator: "; ")) (\(heard))") }
        else if !wanted.isEmpty { report.pass("\(label): \(wanted.joined(separator: ", ")) (\(heard))") }
        else { report.info("\(label): \(heard)") }
    }
    h.hold = []
    _ = await offMain { h.run(seconds: 0.2, block: 256) }

    if let png = options.spectrogramPath {
        if writeSpectrogram(recording, sampleRate: rate, marks: marks, to: png) { report.info("spectrogram: \(png)") }
        else { report.warn("could not write the spectrogram to \(png)") }
    }
}
