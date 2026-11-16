// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import Accelerate
import AppKit
import ImageIO
import ScreenCaptureKit

// Pictures of a run: a spectrogram of a scenario, and a snapshot of the editor's window.

func writePNG(_ image: CGImage, to path: String) -> Bool {
    let url = URL(fileURLWithPath: path) as CFURL
    guard let destination = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return false }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination)
}

/// Frequency (30 Hz to 20 kHz, evenly in pitch) against time, level as colour over 96 dB, with
/// a line and a label where each step of the scenario starts.
@MainActor func writeSpectrogram(_ samples: [Float], sampleRate: Double, marks: [(at: Int, label: String)], to path: String) -> Bool {
    let size = 4096, log2n = vDSP_Length(12)
    guard samples.count > size, let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return false }
    defer { vDSP_destroy_fftsetup(setup) }
    let width = 1400, height = 420, top = 26, left = 52
    let hop = max(1, (samples.count - size) / width)
    var window = [Float](repeating: 0, count: size)
    vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    let lowest = 30.0, highest = min(20000, sampleRate / 2)
    // For each row of pixels, the FFT bin it shows.
    let bins = (0..<height).map { row -> Int in
        let hz = lowest * pow(highest / lowest, Double(height - 1 - row) / Double(height - 1))
        return min(size / 2 - 1, max(1, Int((hz / sampleRate * Double(size)).rounded())))
    }
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var real = [Float](repeating: 0, count: size / 2), imaginary = [Float](repeating: 0, count: size / 2)
    var frame = [Float](repeating: 0, count: size), power = [Float](repeating: 0, count: size / 2)
    for column in 0..<width {
        let start = column * hop
        guard start + size <= samples.count else { break }
        for i in 0..<size { let v = samples[start + i]; frame[i] = (v.isFinite ? v : 0) * window[i] }
        real.withUnsafeMutableBufferPointer { r in
            imaginary.withUnsafeMutableBufferPointer { im in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: im.baseAddress!)
                frame.withUnsafeBufferPointer {
                    $0.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: size / 2) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(size / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(size / 2))
            }
        }
        for row in 0..<height {
            // A full-scale sine comes to 0 dB: zrip scales by 2, the window by its sum.
            let amplitude = power[bins[row]].squareRoot() / Float(size)
            let level = max(0, min(1, (20 * log10(max(amplitude, 1e-9)) + 96) / 96))   // −96…0 dB
            let i = (row * width + column) * 4
            // Black, through violet and orange, to pale yellow.
            pixels[i] = UInt8(255 * min(1, level * 1.6))
            pixels[i + 1] = UInt8(255 * max(0, min(1, level * 1.9 - 0.75)))
            pixels[i + 2] = UInt8(255 * (level < 0.5 ? level * 1.3 : max(0.15, 1.3 - level * 1.3) + max(0, level - 0.85) * 4))
            pixels[i + 3] = 255
        }
    }
    let space = CGColorSpaceCreateDeviceRGB()
    let info = CGImageAlphaInfo.premultipliedLast.rawValue
    guard let plot = pixels.withUnsafeMutableBytes({ raw -> CGImage? in
        CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: info)?.makeImage()
    }), let canvas = CGContext(data: nil, width: left + width, height: top + height, bitsPerComponent: 8, bytesPerRow: 0,
                               space: space, bitmapInfo: info) else { return false }
    canvas.setFillColor(CGColor(gray: 0.07, alpha: 1))
    canvas.fill(CGRect(x: 0, y: 0, width: left + width, height: top + height))
    canvas.draw(plot, in: CGRect(x: left, y: 0, width: width, height: height))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: canvas, flipped: false)
    let text: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(white: 0.85, alpha: 1)]
    for hz in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] where hz < highest {
        let y = Double(height - 1) * log(hz / lowest) / log(highest / lowest)
        (hz >= 1000 ? "\(Int(hz / 1000)) kHz" : "\(Int(hz)) Hz").draw(at: NSPoint(x: 4, y: y - 6), withAttributes: text)
        canvas.setFillColor(CGColor(gray: 1, alpha: 0.12))
        canvas.fill(CGRect(x: Double(left), y: y, width: Double(width), height: 1))
    }
    for (n, mark) in marks.enumerated() {
        let x = Double(left) + Double(mark.at) / Double(hop)
        canvas.setFillColor(CGColor(gray: 1, alpha: 0.45))
        canvas.fill(CGRect(x: x, y: 0, width: 1, height: Double(height)))
        let next = n + 1 < marks.count ? Double(left) + Double(marks[n + 1].at) / Double(hop) : Double(left + width)
        NSString(string: mark.label).draw(with: NSRect(x: x + 3, y: Double(height) + 6, width: max(0, next - x - 6), height: 14),
                                          options: [.truncatesLastVisibleLine, .usesLineFragmentOrigin], attributes: text)
    }
    NSGraphicsContext.restoreGraphicsState()
    guard let image = canvas.makeImage() else { return false }
    return writePNG(image, to: path)
}

/// A PNG of the window with the editor in it, the unit's own drawing included (it is drawn by
/// another process, so the window is captured the way the screen shows it). Needs the Screen
/// Recording permission for the terminal. Returns what went wrong, or nil.
@MainActor func snapshot(_ window: NSWindow, to path: String) async -> String? {
    guard #available(macOS 14.0, *) else { return "snapshots need macOS 14 or later" }
    do {
        window.level = .floating   // above other apps for the shot
        window.orderFrontRegardless()
        await pause(0.3)
        defer { window.level = .normal }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let shareable = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            return "the window isn't on screen"
        }
        let configuration = SCStreamConfiguration()
        let scale = window.backingScaleFactor
        let frame = window.frame.size
        configuration.width = Int(frame.width * scale)
        configuration.height = Int(frame.height * scale)
        configuration.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: shareable),
                                                               configuration: configuration)
        return writePNG(image, to: path) ? nil : "could not write \(path)"
    } catch {
        return "\(error.localizedDescription) (the terminal needs the Screen Recording permission: "
            + "System Settings → Privacy & Security → Screen & System Audio Recording)"
    }
}
