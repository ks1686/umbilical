// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalEngine

struct TrackedDownload {
    var id: String
    var engineGID: String?
    var track: Bool
    var outputName: String
    var url: URL?
    var detail: String
    var state: DownloadStatus.State
    var totalLength: Int64
    var completedLength: Int64
    var downloadSpeed: Int64
    var errorMessage: String?
    var filePath: String?
    var historyID: String?
    var fixedTitle: String?

    var allowsPause: Bool {
        track && (state == .active || state == .waiting)
    }

    var allowsResume: Bool {
        track && state == .paused
    }
}

enum RowBuilder {
    static func make(_ item: TrackedDownload) -> DownloadRow {
        let fraction = ByteFormat.fraction(
            completed: item.completedLength,
            total: item.totalLength,
            state: item.state
        )
        let seconds = ByteFormat.remainingSeconds(
            completed: item.completedLength,
            total: item.totalLength,
            speed: item.downloadSpeed
        )
        return DownloadRow(
            id: item.id,
            title: title(for: item),
            detail: item.detail,
            fraction: fraction,
            showsIndeterminateProgress: showsSpinner(item, fraction: fraction),
            speedText: speedText(item),
            etaText: etaText(item, seconds: seconds),
            sizeText: ByteFormat.progressSize(
                completed: item.completedLength,
                total: item.totalLength,
                state: item.state
            ),
            stateText: stateText(item, fraction: fraction),
            errorMessage: item.errorMessage,
            filePath: item.filePath,
            canPause: item.allowsPause,
            canResume: item.allowsResume,
            canRemove: true,
            isComplete: item.state == .complete,
            isActive: item.state == .active,
            showsInMenu: showsInMenu(item.state),
            bytesPerSecond: max(0, item.downloadSpeed)
        )
    }

    static func title(for item: TrackedDownload) -> String {
        if let fixed = item.fixedTitle, !fixed.isEmpty {
            return fixed
        }
        if let filePath = item.filePath, !filePath.isEmpty {
            let name = URL(fileURLWithPath: filePath).lastPathComponent
            if !name.isEmpty {
                return name
            }
        }
        if !item.outputName.isEmpty {
            return item.outputName
        }
        if let url = item.url {
            return title(for: url)
        }
        return "Download"
    }

    private static func title(for url: URL) -> String {
        let last = url.lastPathComponent
        if !last.isEmpty {
            return last
        }
        if let host = url.host, !host.isEmpty {
            return host
        }
        return "Download"
    }

    private static func showsSpinner(_ item: TrackedDownload, fraction: Double?) -> Bool {
        guard fraction == nil else { return false }
        switch item.state {
        case .active, .waiting:
            return true
        case .paused, .error, .complete, .removed:
            return false
        }
    }

    private static func speedText(_ item: TrackedDownload) -> String {
        guard item.state == .active else { return "" }
        return ByteFormat.speed(item.downloadSpeed)
    }

    private static func etaText(_ item: TrackedDownload, seconds: TimeInterval?) -> String {
        guard item.state == .active else { return "" }
        return ByteFormat.eta(seconds)
    }

    private static func stateText(_ item: TrackedDownload, fraction: Double?) -> String {
        switch item.state {
        case .active:
            if let fraction {
                return ByteFormat.percent(fraction)
            }
            return "Starting"
        case .waiting:
            return "Waiting"
        case .paused:
            return "Paused"
        case .error:
            return "Failed"
        case .complete:
            return "Complete"
        case .removed:
            return "Removed"
        }
    }

    private static func showsInMenu(_ state: DownloadStatus.State) -> Bool {
        switch state {
        case .active, .waiting, .paused, .error:
            return true
        case .complete, .removed:
            return false
        }
    }
}
