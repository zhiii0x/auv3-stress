// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import AudioToolbox
import Foundation

let version = "0.1.0"

nonisolated(unsafe) var options = Options()
nonisolated(unsafe) var unitKind = UnitKind.other
nonisolated(unsafe) var started = Date()
let report = Report()

/// Set when a render or a host call shows the extension process is gone; the crash-report check
/// then waits for its report, which macOS writes some seconds later.
nonisolated(unsafe) var extensionDied = false

/// What a render returns once an out-of-process unit has died (a timeout first, mid-render).
let deadStatuses: Set<OSStatus> = [kAudioUnitErr_RenderTimeout, kAudioComponentErr_InstanceInvalidated,
                                   kAudioComponentErr_InstanceTimedOut]

/// What the unit's type says a host should feed it and expect back.
enum UnitKind {
    case instrument, musicEffect, effect, midiProcessor, generator, other

    init(type: OSType) {
        switch type {
        case kAudioUnitType_MusicDevice: self = .instrument
        case kAudioUnitType_MusicEffect: self = .musicEffect
        case kAudioUnitType_Effect: self = .effect
        case kAudioUnitType_MIDIProcessor: self = .midiProcessor
        case kAudioUnitType_Generator: self = .generator
        default: self = .other
        }
    }

    /// Fed MIDI notes while rendering, so a synth has something to play.
    var playsNotes: Bool { self == .instrument || self == .musicEffect || self == .midiProcessor }
    /// A missing MIDI input is a failure for these.
    var needsMIDIIn: Bool { playsNotes }
    /// Expected to produce audio (silence is reported as a warning, never a failure).
    var makesAudio: Bool { self != .midiProcessor }

    var label: String {
        switch self {
        case .instrument: return "instrument"
        case .musicEffect: return "music effect"
        case .effect: return "effect"
        case .midiProcessor: return "MIDI processor"
        case .generator: return "generator"
        case .other: return "other"
        }
    }
}
