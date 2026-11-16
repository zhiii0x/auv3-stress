// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import AppKit
import AudioToolbox
import AVFoundation
import CoreAudioKit

func f(_ x: Float) -> String { String(format: "%.3g", x) }
func ms(since t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }
func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }

/// Rendering is blocking IPC: keep it off the main thread so the editor (a remote view) stays live.
func offMain<T>(_ work: @escaping () -> T) async -> T {
    await withCheckedContinuation { c in
        DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: work()) }
    }
}

final class Flag: @unchecked Sendable { var stop = false }

func instantiate() async throws -> AUAudioUnit {
    try await withCheckedThrowingContinuation { c in
        AUAudioUnit.instantiate(with: options.description, options: .loadOutOfProcess) { au, error in
            if let au { c.resume(returning: au) }
            else { c.resume(throwing: error ?? NSError(domain: "auv3-stress", code: -1)) }
        }
    }
}

// MARK: Parameters

func parameters(_ au: AUAudioUnit) -> [AUParameter] { au.parameterTree?.allParameters ?? [] }

func isStepped(_ p: AUParameter) -> Bool {
    p.valueStrings != nil || p.unit == .indexed || p.unit == .midiNoteNumber || p.unit == .boolean
}

/// A value in the parameter's range, from the shared generator. A range that isn't finite (a
/// definition section 2 reports) gives the minimum, or zero.
func randomValue(_ p: AUParameter) -> AUValue {
    random.draw { randomValue(p, using: &$0) }
}

/// The same, from a generator of the caller's (a thread that draws at its own pace).
func randomValue(_ p: AUParameter, using generator: inout SplitMix64) -> AUValue {
    let low = p.minValue, high = p.maxValue
    guard low.isFinite, high.isFinite, low < high, (high - low).isFinite else { return low.isFinite ? low : 0 }
    if isStepped(p), abs(low) < 1e9, abs(high) < 1e9, Int(low) <= Int(high) {
        return AUValue(Int.random(in: Int(low)...Int(high), using: &generator))
    }
    return AUValue.random(in: low...high, using: &generator)
}

func values(_ au: AUAudioUnit) -> [AUParameterAddress: AUValue] {
    Dictionary(parameters(au).map { ($0.address, $0.value) }, uniquingKeysWith: { a, _ in a })
}

func names(_ au: AUAudioUnit) -> [AUParameterAddress: String] {
    Dictionary(parameters(au).map { ($0.address, $0.identifier) }, uniquingKeysWith: { a, _ in a })
}

func diffs(_ a: [AUParameterAddress: AUValue], _ b: [AUParameterAddress: AUValue],
           names: [AUParameterAddress: String], skip: Set<AUParameterAddress> = []) -> [String] {
    a.keys.sorted().compactMap { k in
        guard !skip.contains(k), let x = a[k], let y = b[k] else { return nil }
        return abs(x - y) <= max(1e-4, abs(x) * 1e-4) ? nil : "\(names[k] ?? "\(k)") \(f(x))→\(f(y))"
    }
}

/// Top-level keys whose values differ between two states. Data that parses as JSON or a property
/// list is compared parsed: key order in a serialized dictionary can differ between processes
/// (Swift seeds its hashing per process) without anything having changed.
func stateDiff(_ a: [String: Any]?, _ b: [String: Any]?) -> [String] {
    guard let a, let b else { return ["(no state)"] }
    func parsed(_ v: Any?) -> NSObject? {
        guard let d = v as? Data else { return v as? NSObject }
        if let j = try? JSONSerialization.jsonObject(with: d, options: [.fragmentsAllowed]) as? NSObject { return j }
        if let p = try? PropertyListSerialization.propertyList(from: d, format: nil) as? NSObject { return p }
        return d as NSObject
    }
    return Set(a.keys).union(b.keys).sorted().filter { k in
        guard let x = parsed(a[k]), let y = parsed(b[k]) else { return (a[k] == nil) != (b[k] == nil) }
        return !x.isEqual(y)
    }
}

func preview(_ list: [String], _ n: Int = 6) -> String {
    list.prefix(n).joined(separator: ", ") + (list.count > n ? " … (+\(list.count - n))" : "")
}

// MARK: Editor

@MainActor func requestEditor(_ au: AUAudioUnit) async -> NSViewController? {
    await withCheckedContinuation { c in au.requestViewController { vc in c.resume(returning: vc) } }
}

@MainActor func showWindow(_ vc: NSViewController, size: NSSize, at origin: NSPoint, title: String) -> NSWindow {
    let w = NSWindow(contentRect: NSRect(origin: origin, size: size), styleMask: [.titled, .closable, .resizable],
                     backing: .buffered, defer: false)
    w.title = title
    w.isReleasedWhenClosed = false
    w.contentViewController = vc
    w.setContentSize(size)
    w.setFrameOrigin(origin)
    w.orderFrontRegardless()
    return w
}

@MainActor func closeWindow(_ w: NSWindow) {
    w.contentViewController = nil
    w.close()
}

// MARK: The extension process

func shell(_ path: String, _ args: [String]) -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let out = Pipe()
    p.standardOutput = out
    p.standardError = Pipe()
    do { try p.run() } catch { return "" }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return String(data: data, encoding: .utf8) ?? ""
}

/// The executable name of the app extension that provides the unit (an AUv3), found through
/// pluginkit and the extension's AudioComponents list. nil for a v2 unit or when not found.
func extensionExecutable(for desc: AudioComponentDescription) -> String? {
    for point in ["com.apple.AudioUnit-UI", "com.apple.AudioUnit"] {
        for line in shell("/usr/bin/pluginkit", ["-m", "-v", "-p", point]).split(separator: "\n") {
            guard let path = line.split(separator: "\t").last.map({ $0.trimmingCharacters(in: .whitespaces) }),
                  path.hasSuffix(".appex"), let bundle = Bundle(path: path),
                  let ext = bundle.infoDictionary?["NSExtension"] as? [String: Any],
                  let attrs = ext["NSExtensionAttributes"] as? [String: Any],
                  let comps = attrs["AudioComponents"] as? [[String: Any]] else { continue }
            let match = comps.contains { c in
                (c["type"] as? String).flatMap(fourCC) == desc.componentType
                    && (c["subtype"] as? String).flatMap(fourCC) == desc.componentSubType
                    && (c["manufacturer"] as? String).flatMap(fourCC) == desc.componentManufacturer
            }
            if match { return bundle.infoDictionary?["CFBundleExecutable"] as? String }
        }
    }
    return nil
}

/// Resident memory of a process by executable name (KB), if it is running.
func residentKB(of process: String?) -> Int? {
    guard let process else { return nil }
    guard let pid = shell("/usr/bin/pgrep", ["-x", process]).split(separator: "\n").first else { return nil }
    return Int(shell("/bin/ps", ["-o", "rss=", "-p", String(pid)]).trimmingCharacters(in: .whitespacesAndNewlines))
}

// MARK: --list

func listUnits() {
    let all = AVAudioUnitComponentManager.shared().components(matching: AudioComponentDescription())
    let rows = all.map { c -> (String, String) in
        let d = c.audioComponentDescription
        let code = "\(fourCCString(d.componentType)) \(fourCCString(d.componentSubType)) \(fourCCString(d.componentManufacturer))"
        let v3 = d.componentFlags & AudioComponentFlags.isV3AudioUnit.rawValue != 0
        return (code, "\(c.manufacturerName): \(c.name)\(v3 ? "  (v3)" : "")")
    }.sorted { $0.0 < $1.0 }
    for (code, name) in rows { print("\(code)  \(name)") }
    print("\n\(rows.count) audio units. Test one with: auv3-stress <type> <subtype> <manufacturer>")
}
