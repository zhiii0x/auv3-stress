// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import Foundation

// Listening to what was rendered: steps in the waveform (clicks), pitch, and WAV files of it all.

/// The biggest step between two neighbouring samples.
func sharpestEdge(_ x: [Float]) -> Float {
    guard x.count > 1 else { return 0 }
    var worst: Float = 0
    for n in 1..<x.count where x[n].isFinite && x[n - 1].isFinite { worst = max(worst, abs(x[n] - x[n - 1])) }
    return worst
}

/// The fundamental between 60 and 1000 Hz, by autocorrelation, and how periodic the sound is
/// there (1 is exactly periodic). nil for silence.
func pitch(of samples: [Float], sampleRate: Double) -> (hz: Double, confidence: Double)? {
    let n = min(samples.count, 8192)
    guard n >= 2048 else { return nil }
    var x = Array(samples.suffix(n))
    let mean = x.reduce(0, +) / Float(n)
    for i in 0..<n { x[i] -= mean }
    let minLag = Int(sampleRate / 1000), maxLag = min(Int(sampleRate / 60), n / 2)
    guard minLag < maxLag else { return nil }
    let span = n - maxLag
    var energy = [Double](repeating: 0, count: n + 1)   // running sum of squares
    for i in 0..<n { energy[i + 1] = energy[i] + Double(x[i] * x[i]) }
    guard energy[span] > 1e-9 else { return nil }
    var r = [Double](repeating: 0, count: maxLag + 1)
    for lag in minLag...maxLag {
        var sum: Float = 0
        for i in 0..<span { sum += x[i] * x[i + lag] }
        let scale = (energy[span] * (energy[span + lag] - energy[lag])).squareRoot()
        r[lag] = scale > 0 ? Double(sum) / scale : 0
    }
    guard let best = r.max(), best > 0 else { return nil }
    // The shortest lag that is a peak and nearly as good as the best: the period, not a multiple.
    var lag = minLag + 1
    while lag < maxLag && !(r[lag] >= 0.95 * best && r[lag] >= r[lag - 1] && r[lag] >= r[lag + 1]) { lag += 1 }
    guard lag < maxLag else { return nil }
    let a = r[lag - 1], b = r[lag], c = r[lag + 1]
    let shift = (a - 2 * b + c) != 0 ? 0.5 * (a - c) / (a - 2 * b + c) : 0
    return (sampleRate / (Double(lag) + shift), b)
}

func cents(_ hz: Double, from reference: Double) -> Double { 1200 * log2(hz / reference) }

// MARK: --save-audio

/// A 32-bit float WAV file, written as the audio is rendered.
final class WavWriter {
    private let handle: FileHandle
    private var pending = Data()
    private var bytes = 0
    private var closed = false

    init?(url: URL, sampleRate: Double, channels: Int) {
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let h = try? FileHandle(forWritingTo: url) else { return nil }
        handle = h
        func le<T: FixedWidthInteger>(_ v: T) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var head = Data("RIFF".utf8) + le(UInt32(0)) + Data("WAVEfmt ".utf8) + le(UInt32(16))
        let rate = UInt32(max(1, min(sampleRate, 4_000_000))), count = UInt16(clamping: channels)
        head += le(UInt16(3)) + le(count) + le(rate) + le(rate * UInt32(count) * 4)
        head += le(count * 4) + le(UInt16(32)) + Data("data".utf8) + le(UInt32(0))
        handle.write(head)
    }

    func append(_ interleaved: [Float]) {
        interleaved.withUnsafeBytes { pending.append(contentsOf: $0) }
        if pending.count > 1 << 20 { flush() }
    }

    private func flush() {
        handle.write(pending)
        bytes += pending.count
        pending.removeAll(keepingCapacity: true)
    }

    func close() {
        guard !closed else { return }
        closed = true
        flush()
        func le(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        // Past 4 GB a WAV header can't say how long the file is; the audio is still all there.
        handle.seek(toFileOffset: 4); handle.write(le(UInt32(clamping: 36 + bytes)))
        handle.seek(toFileOffset: 40); handle.write(le(UInt32(clamping: bytes)))
        try? handle.close()
    }
}

/// The WAV files of a run: one for each host the checks set up (a section sets up several, at
/// different sample rates and layouts), named by section and order.
final class AudioLog: @unchecked Sendable {
    private let lock = NSLock()
    private var writers: [WavWriter] = []
    private var count = 0

    func writer(sampleRate: Double, channels: Int) -> WavWriter? {
        guard let dir = options.audioDir else { return nil }
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        count += 1
        let section = Int(report.sectionName.prefix { $0.isNumber }) ?? 0
        let name = String(format: "%02d-%03d-%dHz.wav", section, count, Int(sampleRate))
        guard let w = WavWriter(url: URL(fileURLWithPath: dir).appendingPathComponent(name), sampleRate: sampleRate,
                                channels: channels) else { return nil }
        writers.append(w)
        return w
    }

    func closeAll() -> Int {
        lock.lock(); defer { lock.unlock() }
        writers.forEach { $0.close() }
        return writers.count
    }
}

let audioLog = AudioLog()
