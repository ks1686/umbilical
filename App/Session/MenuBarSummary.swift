// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum MenuBarSummary {
    static let idleTitle = ""

    static func title(for rows: [DownloadRow]) -> String {
        let active = rows.filter(\.isActive)
        if active.isEmpty {
            return idleTitle
        }
        let speed = active.reduce(Int64(0), addSpeed)
        if active.count == 1, let fraction = active[0].fraction {
            return "\(ByteFormat.percent(fraction)) \(ByteFormat.speed(speed))"
        }
        return "\(active.count) \(ByteFormat.speed(speed))"
    }

    static func items(for rows: [DownloadRow]) -> [MenuDownload] {
        rows.filter(\.showsInMenu).map { row in
            MenuDownload(id: row.id, label: "\(row.title) \(row.stateText)")
        }
    }

    private static func addSpeed(_ total: Int64, _ row: DownloadRow) -> Int64 {
        let value = max(0, row.bytesPerSecond)
        if total > Int64.max - value {
            return Int64.max
        }
        return total + value
    }
}
