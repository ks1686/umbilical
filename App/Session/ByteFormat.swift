// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalEngine

enum ByteFormat {
    private static let posix = Locale(identifier: "en_US_POSIX")
    private static let units = ["B", "KB", "MB", "GB", "TB"]

    static func size(_ bytes: Int64) -> String {
        let value = bytes > 0 ? bytes : 0
        var amount = Double(value)
        var unit = 0
        while amount >= 1024, unit < units.count - 1 {
            amount /= 1024
            unit += 1
        }
        if unit == 0 {
            return "\(Int(amount)) B"
        }
        return "\(decimal(amount)) \(units[unit])"
    }

    static func speed(_ bytesPerSecond: Int64) -> String {
        "\(size(bytesPerSecond))/s"
    }

    static func percent(_ fraction: Double) -> String {
        guard fraction.isFinite else { return "0%" }
        let value = Int((fraction * 100).rounded())
        return "\(min(100, max(0, value)))%"
    }

    static func fraction(
        completed: Int64,
        total: Int64,
        state: DownloadStatus.State
    ) -> Double? {
        if state == .complete {
            return 1
        }
        guard total > 0 else { return nil }
        let done = min(max(completed, 0), total)
        return Double(done) / Double(total)
    }

    static func remainingSeconds(
        completed: Int64,
        total: Int64,
        speed: Int64
    ) -> TimeInterval? {
        guard speed > 0, total > 0 else { return nil }
        let done = min(max(completed, 0), total)
        let remaining = total - done
        if remaining == 0 {
            return 0
        }
        return Double(remaining) / Double(speed)
    }

    static func eta(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded(.down))
        if total < 60 {
            return "\(total)s"
        }
        let minutes = total / 60
        if minutes < 60 {
            return "\(minutes)m \(total % 60)s"
        }
        let hours = minutes / 60
        let remain = minutes % 60
        return "\(hours)h \(String(format: "%02d", locale: posix, remain))m"
    }

    static func progressSize(
        completed: Int64,
        total: Int64,
        state: DownloadStatus.State
    ) -> String {
        if state == .complete {
            let bytes = total > 0 ? total : max(completed, 0)
            return size(bytes)
        }
        if total > 0 {
            return "\(size(max(completed, 0))) of \(size(total))"
        }
        if completed > 0 {
            return size(completed)
        }
        return ""
    }

    private static func decimal(_ amount: Double) -> String {
        String(format: "%.1f", locale: posix, amount)
    }
}
