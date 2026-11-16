// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import AppKit

setvbuf(stdout, nil, _IOLBF, 0)
options = Options.parse(Array(CommandLine.arguments.dropFirst()))
if options.list {
    listUnits()
    exit(0)
}
unitKind = UnitKind(type: options.type)
random.reseed(options.seed)
print("auv3-stress \(version): \(options.unitCode), seed \(options.seed)")
started = Date()

DispatchQueue.global().asyncAfter(deadline: .now() + 900) {
    print("\n✗ watchdog: still running after 15 minutes, something hung")
    report.fail("still running after 15 minutes: something hung")
    _ = finish(name: "")   // the reports and the WAV files, as far as the run got
    exit(2)
}

// The editor checks need a running AppKit app (remote view controllers live in windows).
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
Task { @MainActor in
    let code = await runAll()
    exit(code)
}
app.run()
