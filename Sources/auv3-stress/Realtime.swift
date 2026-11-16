// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 zhiii0x

import AudioToolbox
import Darwin
import Foundation

// A thread scheduled the way an audio device's I/O thread is, so render can be timed under the
// conditions it has in a host: a deadline every buffer, and nothing allowed to wait.

/// Asks the kernel for real-time (time-constraint) scheduling for the calling thread, with a
/// deadline every `period` seconds. False when the kernel refuses.
func makeThreadRealtime(period: Double) -> Bool {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    let ticks = period * 1e9 * Double(timebase.denom) / Double(timebase.numer)
    var policy = thread_time_constraint_policy_data_t(period: UInt32(ticks), computation: UInt32(ticks * 0.5),
                                                      constraint: UInt32(ticks), preemptible: 1)
    let count = mach_msg_type_number_t(MemoryLayout<thread_time_constraint_policy_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &policy) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            thread_policy_set(pthread_mach_thread_np(pthread_self()), thread_policy_flavor_t(THREAD_TIME_CONSTRAINT_POLICY), $0, count)
        }
    }
    return result == KERN_SUCCESS
}

/// Runs `work` on a new real-time thread. `work` is told whether the thread got real-time scheduling.
func onRealtimeThread<T>(period: Double, _ work: @escaping (Bool) -> T) async -> T {
    await withCheckedContinuation { c in
        let thread = Thread { c.resume(returning: work(makeThreadRealtime(period: period))) }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}

extension Host {
    /// `seconds` of audio in `block`-frame buffers, one buffer every buffer's worth of time, as a
    /// device asks for them. A late buffer isn't made up for: the next one waits for its own slot.
    @discardableResult
    func runPaced(seconds: Double, block: AUAudioFrameCount, before: ((Host) -> Void)? = nil) -> Bool {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let period = UInt64(Double(block) / sampleRate * 1e9 * Double(timebase.denom) / Double(timebase.numer))
        var deadline = mach_absolute_time() + period
        for _ in 0..<Int(seconds * sampleRate / Double(block)) {
            before?(self)
            if render(block) != noErr { return false }
            let now = mach_absolute_time()
            if now < deadline { mach_wait_until(deadline) }
            deadline = max(deadline, now) + period
        }
        return true
    }
}
