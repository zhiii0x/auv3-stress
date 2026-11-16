// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import AVFoundation
import XCTest
@testable import auv3_stress

/// The parts that can be tested without loading an Audio Unit: what the checks measure with, the
/// command line, the seeded generator and the WAV writer.
final class AnalysisTests: XCTestCase {
    private func sine(_ hz: Double, rate: Double, seconds: Double = 0.4, amplitude: Float = 0.25) -> [Float] {
        (0..<Int(rate * seconds)).map { amplitude * Float(sin(2 * Double.pi * hz * Double($0) / rate)) }
    }

    func testPitchOfASineAtEverySampleRate() throws {
        for rate in [44100.0, 48000, 96000] {
            for hz in [110.0, 220, 440, 880] {
                let p = try XCTUnwrap(pitch(of: sine(hz, rate: rate), sampleRate: rate), "\(hz) Hz at \(rate)")
                XCTAssertLessThan(abs(cents(p.hz, from: hz)), 5, "\(hz) Hz at \(rate) heard as \(p.hz)")
                XCTAssertGreaterThan(p.confidence, 0.95)
            }
        }
    }

    func testPitchFindsTheFundamentalUnderHarmonics() throws {
        let rate = 48000.0
        let rich = zip(zip(sine(220, rate: rate), sine(440, rate: rate, amplitude: 0.2)), sine(660, rate: rate, amplitude: 0.15))
            .map { $0.0.0 + $0.0.1 + $0.1 }
        let p = try XCTUnwrap(pitch(of: rich, sampleRate: rate))
        XCTAssertLessThan(abs(cents(p.hz, from: 220)), 5)
    }

    func testPitchOfSilenceAndNoise() {
        XCTAssertNil(pitch(of: [Float](repeating: 0, count: 20000), sampleRate: 48000))
        var generator = SplitMix64(seed: 1)
        let noise = (0..<20000).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
        if let p = pitch(of: noise, sampleRate: 48000) { XCTAssertLessThan(p.confidence, 0.9) }
    }

    func testCents() {
        XCTAssertEqual(cents(440, from: 220), 1200, accuracy: 1e-9)
        XCTAssertEqual(cents(220, from: 220), 0, accuracy: 1e-9)
    }

    func testSharpestEdgeSeesAStep() {
        var x = sine(220, rate: 48000)
        let steady = sharpestEdge(x)
        XCTAssertEqual(steady, 0.25 * Float(2 * Double.pi * 220 / 48000), accuracy: 1e-3)
        for i in 9000..<x.count { x[i] *= 0.1 }   // a gain applied in one sample, away from a zero crossing
        XCTAssertGreaterThan(sharpestEdge(x), 4 * steady)
        XCTAssertEqual(sharpestEdge([]), 0)
        XCTAssertEqual(sharpestEdge([0.5]), 0)
        XCTAssertEqual(sharpestEdge([0, .nan, 1]), 0)
    }

    func testFourCharacterCodes() {
        XCTAssertEqual(fourCC("aumu"), 0x61756D75)
        XCTAssertEqual(fourCC("dls"), fourCC("dls "))
        XCTAssertNil(fourCC("toolong"))
        XCTAssertEqual(fourCCString(0x61756D75), "aumu")
    }

    func testSkipAddresses() {
        XCTAssertEqual(parseAddresses("96,100-103"), [96, 100, 101, 102, 103])
        XCTAssertNil(parseAddresses(""))
        XCTAssertNil(parseAddresses("5-3"))
        XCTAssertNil(parseAddresses("abc"))
    }

    func testTheSeedRepeats() {
        var a = SplitMix64(seed: 42), b = SplitMix64(seed: 42), c = SplitMix64(seed: 43)
        let first = (0..<8).map { _ in a.next() }
        XCTAssertEqual(first, (0..<8).map { _ in b.next() })
        XCTAssertNotEqual(first, (0..<8).map { _ in c.next() })
    }

    func testWavFilesOpen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("auv3-stress-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = try XCTUnwrap(WavWriter(url: url, sampleRate: 44100, channels: 2))
        let tone = sine(440, rate: 44100, seconds: 0.5)
        writer.append(tone.flatMap { [$0, -$0] })
        writer.close()
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 44100)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.length, AVAudioFramePosition(tone.count))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(tone.count)))
        try file.read(into: buffer)
        XCTAssertEqual(buffer.floatChannelData![0][100], tone[100], accuracy: 1e-6)
        XCTAssertEqual(buffer.floatChannelData![1][100], -tone[100], accuracy: 1e-6)
    }
}
