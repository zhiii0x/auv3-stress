// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import Foundation

/// Console output, counts, and the optional JSON file.
final class Report {
    struct Entry: Encodable {
        let section: String
        let result: String   // pass, fail, warn, info
        let message: String
    }

    private(set) var fails = 0
    private(set) var warns = 0
    private(set) var entries: [Entry] = []
    private var current = ""
    var sectionName: String { current }

    func section(_ name: String) { current = name; print("\n▸ \(name)") }
    func pass(_ msg: String) { log("pass", msg); print("  ✓ \(msg)") }
    func info(_ msg: String) { log("info", msg); print("    \(msg)") }
    func fail(_ msg: String) { fails += 1; log("fail", msg); print("  ✗ FAIL [\(current)] \(msg)") }
    func warn(_ msg: String) { warns += 1; log("warn", msg); print("  ! WARN [\(current)] \(msg)") }

    private func log(_ result: String, _ message: String) {
        entries.append(Entry(section: current, result: result, message: message))
    }

    /// Failed, as the exit status says it: with --strict a warning fails too.
    var failed: Bool { fails > 0 || (options.strict && warns > 0) }

    /// JUnit XML as CI systems read it: a test suite per section, a test case per result. Failures
    /// are <failure>; warnings are <failure> with --strict and <system-out> otherwise.
    func writeJUnit(to path: String, unit: String, name: String, seconds: Int) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        var sections: [String] = []
        for e in entries where !sections.contains(e.section) { sections.append(e.section) }
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        xml += "<testsuites name=\"auv3-stress \(esc(unit))\" tests=\"\(entries.count)\" "
            + "failures=\"\(fails + (options.strict ? warns : 0))\" time=\"\(seconds)\">\n"
        for section in sections {
            let cases = entries.filter { $0.section == section }
            let failing = cases.filter { $0.result == "fail" || (options.strict && $0.result == "warn") }
            xml += "  <testsuite name=\"\(esc(section))\" tests=\"\(cases.count)\" failures=\"\(failing.count)\">\n"
            xml += "    <properties><property name=\"unit\" value=\"\(esc(name))\"/>"
                + "<property name=\"seed\" value=\"\(options.seed)\"/></properties>\n"
            for c in cases {
                let open = "    <testcase classname=\"\(esc(section))\" name=\"\(esc(c.message))\""
                switch c.result {
                case "fail": xml += open + "><failure message=\"\(esc(c.message))\"/></testcase>\n"
                case "warn" where options.strict: xml += open + "><failure message=\"warning: \(esc(c.message))\"/></testcase>\n"
                case "warn": xml += open + "><system-out>warning</system-out></testcase>\n"
                default: xml += open + "/>\n"
                }
            }
            xml += "  </testsuite>\n"
        }
        xml += "</testsuites>\n"
        do { try Data(xml.utf8).write(to: URL(fileURLWithPath: path)) }
        catch { print("! could not write \(path): \(error.localizedDescription)") }
    }

    func writeJSON(to path: String, unit: String, name: String, seconds: Int) {
        struct Output: Encodable {
            let version: String
            let unit: String
            let name: String
            let seed: UInt64
            let strict: Bool
            let passed: Bool
            let fails: Int
            let warnings: Int
            let seconds: Int
            let results: [Entry]
        }
        let out = Output(version: version, unit: unit, name: name, seed: options.seed, strict: options.strict, passed: !failed,
                         fails: fails, warnings: warns,
                         seconds: seconds, results: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(out).write(to: URL(fileURLWithPath: path))
        } catch {
            print("! could not write \(path): \(error.localizedDescription)")
        }
    }
}
