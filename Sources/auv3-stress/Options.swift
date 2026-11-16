// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import AppKit
import AudioToolbox
import Foundation

/// The command line.
struct Options {
    var type: OSType = 0
    var subtype: OSType = 0
    var manufacturer: OSType = 0
    var skip = Set<AUParameterAddress>()
    var editor = true
    var jsonPath: String?
    var junitPath: String?
    var audioDir: String?
    var scenarioPath: String?
    var spectrogramPath: String?
    var snapshotPath: String?
    var windowSize: NSSize?
    var list = false
    /// Seeds every random choice; a random one unless --seed gives it.
    var seed = UInt64.random(in: 1...999_999_999)
    /// Warnings fail the run too.
    var strict = false

    var description: AudioComponentDescription {
        AudioComponentDescription(componentType: type, componentSubType: subtype,
                                  componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0)
    }

    /// "aumu dls  appl"
    var unitCode: String { "\(fourCCString(type)) \(fourCCString(subtype)) \(fourCCString(manufacturer))" }

    static let usage = """
    usage: auv3-stress <type> <subtype> <manufacturer> [options]
           auv3-stress --list

    Stress-tests an Audio Unit the way a host uses it: loaded out of process, rendered at several
    sample rates and block sizes, fuzzed through its parameters and MIDI input, automated inside
    render, saved and restored (also while rendering, also with garbage), run as several instances
    at once, opened and closed, fed hostile audio and MIDI, moved around the timeline, timed, and
    with its editor opened, resized and closed while audio runs.

    Codes are the unit's four-character type, subtype and manufacturer, as `auv3-stress --list` shows
    them, e.g.  auv3-stress aumu dls appl   or   auv3-stress aufx dely appl

    options:
      --skip <addresses>  parameters to leave out of fuzzing, read-back and state comparisons,
                          e.g. --skip 96,100-111 (ones that are reset on purpose, or select modes)
      --no-editor         skip the editor checks (no windows appear on screen)
      --json <path>       also write the results to a JSON file
      --junit <path>      also write them as JUnit XML (one test case per check, for CI)
      --save-audio <dir>  save what was rendered there as WAV files (one per host set up,
                          named by section), to listen to what the checks measured
      --scenario <json>   play a scenario (notes, parameter changes and sweeps, step by step)
                          and judge each step, instead of the standard checks
      --spectrogram <png> with --scenario: a spectrogram of what it played, steps marked
      --snapshot <png>    save a picture of the editor's window (needs the Screen Recording
                          permission for the terminal; not with --no-editor)
      --window-size <WxH> open the editor at this content size, e.g. 1400x460
      --seed <number>     repeat a run: the same random parameter values, MIDI and garbage
                          (every run prints its seed)
      --strict            warnings fail the run too (exit status 1)
      --list              list the audio units installed on this Mac
      --version           print the version
      -h, --help          show this text

    exit status: 0 passed, 1 failed, 2 hung (15-minute watchdog), 64 usage error
    """

    static func parse(_ args: [String]) -> Options {
        var o = Options()
        var positional: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            switch a {
            case "-h", "--help":
                print(usage)
                exit(0)
            case "--version":
                print("auv3-stress \(version)")
                exit(0)
            case "--list":
                o.list = true
            case "--no-editor":
                o.editor = false
            case "--json":
                i += 1
                guard i < args.count else { usageError("--json needs a path") }
                o.jsonPath = args[i]
            case "--junit":
                i += 1
                guard i < args.count else { usageError("--junit needs a path") }
                o.junitPath = args[i]
            case "--save-audio":
                i += 1
                guard i < args.count else { usageError("--save-audio needs a folder") }
                o.audioDir = args[i]
            case "--scenario", "--spectrogram", "--snapshot":
                i += 1
                guard i < args.count else { usageError("\(a) needs a path") }
                if a == "--scenario" { o.scenarioPath = args[i] }
                else if a == "--spectrogram" { o.spectrogramPath = args[i] }
                else { o.snapshotPath = args[i] }
            case "--window-size":
                i += 1
                let fields = i < args.count ? args[i].lowercased().split(separator: "x", omittingEmptySubsequences: false) : []
                let parts = fields.compactMap { Double($0) }.filter { (100...10000).contains($0) }
                guard fields.count == 2, parts.count == 2 else { usageError("--window-size needs a size from 100 to 10000 points, e.g. 1400x460") }
                o.windowSize = NSSize(width: parts[0], height: parts[1])
            case "--seed":
                i += 1
                guard i < args.count, let s = UInt64(args[i]) else { usageError("--seed needs a number") }
                o.seed = s
            case "--strict":
                o.strict = true
            case "--skip":
                i += 1
                guard i < args.count, let s = parseAddresses(args[i]) else {
                    usageError("--skip needs parameter addresses, e.g. --skip 96,100-111")
                }
                o.skip.formUnion(s)
            default:
                if a.hasPrefix("--") { usageError("unknown option \(a)") }
                positional.append(a)
            }
            i += 1
        }
        if o.list { return o }
        if o.spectrogramPath != nil && o.scenarioPath == nil { usageError("--spectrogram goes with --scenario") }
        if o.snapshotPath != nil && !o.editor { usageError("--snapshot needs the editor: not with --no-editor") }
        guard positional.count == 3 else {
            usageError("expected <type> <subtype> <manufacturer>, e.g. auv3-stress aumu dls appl")
        }
        guard let t = fourCC(positional[0]), let s = fourCC(positional[1]), let m = fourCC(positional[2]) else {
            usageError("type, subtype and manufacturer are four-character codes, e.g. aumu")
        }
        o.type = t
        o.subtype = s
        o.manufacturer = m
        return o
    }
}

func usageError(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("auv3-stress: \(msg)\n\n\(Options.usage)\n".utf8))
    exit(64)
}

/// "dls" → "dls " (codes shorter than four characters are space-padded, as Apple's are).
func fourCC(_ s: String) -> OSType? {
    let padded = s.count < 4 ? s + String(repeating: " ", count: 4 - s.count) : s
    // Mac Roman, as --list prints them: a code may have a byte over 127 (©, ™).
    guard let bytes = padded.data(using: .macOSRoman).map(Array.init), bytes.count == 4 else { return nil }
    return bytes.reduce(0) { ($0 << 8) | OSType($1) }
}

func fourCCString(_ c: OSType) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((c >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .macOSRoman) ?? String(c)
}

/// "96,100-111" → {96, 100, …, 111}
func parseAddresses(_ s: String) -> Set<AUParameterAddress>? {
    var out = Set<AUParameterAddress>()
    for part in s.split(separator: ",") {
        let r = part.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        if r.count == 2, let a = AUParameterAddress(r[0]), let b = AUParameterAddress(r[1]), a <= b, b - a < 1_000_000 {
            out.formUnion(a...b)
        } else if r.count == 1, let a = AUParameterAddress(r[0]) {
            out.insert(a)
        } else {
            return nil
        }
    }
    return out.isEmpty ? nil : out
}
