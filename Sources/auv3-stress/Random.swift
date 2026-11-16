// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import Foundation

// Every random choice the checks make comes from one seeded generator, so a run that found
// something can be repeated with --seed. (The values repeat exactly; how they interleave with the
// render thread in the concurrent sections still depends on timing.)

struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The shared generator; locked, because the parameter-writing thread draws from it too.
final class SharedRandom: @unchecked Sendable {
    private let lock = NSLock()
    private var generator = SplitMix64(seed: 0)
    private var forks: UInt64 = 0

    func reseed(_ seed: UInt64) { lock.lock(); generator = SplitMix64(seed: seed); forks = 0; lock.unlock() }

    func draw<T>(_ body: (inout SplitMix64) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&generator)
    }

    /// A generator of its own for a render thread (the input noise), not shared and not locked.
    func fork() -> SplitMix64 {
        lock.lock(); defer { lock.unlock() }
        forks += 1
        return SplitMix64(seed: options.seed ^ (forks &* 0xD6E8_FEB8_6659_FD93))
    }
}

let random = SharedRandom()

func rnd<T: FixedWidthInteger>(_ range: ClosedRange<T>) -> T { random.draw { T.random(in: range, using: &$0) } }
func rnd<T: FixedWidthInteger>(_ range: Range<T>) -> T { random.draw { T.random(in: range, using: &$0) } }
func rnd<T: BinaryFloatingPoint>(_ range: ClosedRange<T>) -> T where T.RawSignificand: FixedWidthInteger {
    random.draw { T.random(in: range, using: &$0) }
}
func rndBool() -> Bool { random.draw { Bool.random(using: &$0) } }
func pick<C: Collection>(_ items: C) -> C.Element? { random.draw { items.randomElement(using: &$0) } }
