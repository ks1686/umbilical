// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalEngine

extension DownloadSessionModel {
    func chooseDownloadDirectory(_ folder: URL) throws {
        let accepted = try DownloadFolderRules.acceptRoot(folder)
        if hasActiveWork {
            throw SessionError.folderChangeBlocked
        }
        directory = accepted
        settings.downloadDirectoryPath = accepted.path
        store.saveSettings(settings)
        if phase == .needsFolder {
            setMessage(nil)
        }
        rebuild()
    }

    func setMessage(_ text: String?) {
        message = text
        refreshOwnsMessage = false
    }

    func stopsInEngine(_ item: TrackedDownload) -> Bool {
        item.track && item.state != .removed
    }

    func listedFiles(gid: String, client: any DownloadControlling) async -> [URL] {
        do {
            return try await client.files(gid: gid)
        } catch {
            return []
        }
    }

    /// aria2.remove only requests a halt. The daemon may rewrite the .aria2
    /// control file after that RPC returns.
    func waitUntilEngineReleased(gid: String, client: any DownloadControlling) async {
        for _ in 0..<50 {
            do {
                let status = try await client.status(gid: gid)
                if status.state == .removed {
                    return
                }
            } catch {
                return
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func cleanupFiles(for item: TrackedDownload, listed: [URL]) -> [URL] {
        var files = listed
        if let path = item.filePath, !path.isEmpty {
            files.append(URL(fileURLWithPath: path))
        }
        return files
    }

    func change(
        id: String,
        allow: KeyPath<TrackedDownload, Bool>,
        call: (any DownloadControlling, String) async throws -> Void,
        apply change: (inout TrackedDownload) -> Void
    ) async {
        guard let index = index(of: id), tracked[index][keyPath: allow] else { return }
        guard let gid = tracked[index].engineGID, let client else { return }
        do {
            try await call(client, gid)
            change(&tracked[index])
            setMessage(nil)
        } catch {
            setMessage(DownloadMessage.text(for: error))
        }
        rebuild()
    }

    func apply(_ status: DownloadStatus, to index: Int) {
        let previous = tracked[index].state
        tracked[index].state = status.state
        tracked[index].totalLength = status.totalLength
        tracked[index].completedLength = status.completedLength
        tracked[index].downloadSpeed = status.downloadSpeed
        tracked[index].errorMessage = status.errorMessage.map(DownloadMessage.redact)
        tracked[index].filePath = acceptedFile(status.files)
        if previous != .complete, status.state == .complete {
            finish(index)
        } else if previous != .error, status.state == .error, settings.notifyOnFailure {
            notices.append(notice(kind: .failed, item: tracked[index]))
        }
    }

    func finish(_ index: Int) {
        tracked[index].track = false
        tracked[index].downloadSpeed = 0
        tracked[index].fixedTitle = RowBuilder.title(for: tracked[index])
        let entry = historyEntry(tracked[index])
        tracked[index].historyID = entry.id
        remember(entry)
        if settings.notifyOnComplete {
            notices.append(notice(kind: .completed, item: tracked[index]))
        }
    }

    func historyEntry(_ item: TrackedDownload) -> FinishedDownload {
        let stamp = Int(clock().timeIntervalSince1970)
        let gid = item.engineGID ?? item.id
        let bytes = item.totalLength > 0 ? item.totalLength : item.completedLength
        return FinishedDownload(
            id: "history-\(gid)-\(stamp)",
            title: item.fixedTitle ?? RowBuilder.title(for: item),
            detail: item.detail,
            totalLength: bytes,
            filePath: item.filePath,
            finishedAt: clock()
        )
    }

    func notice(kind: DownloadNotice.Kind, item: TrackedDownload) -> DownloadNotice {
        let heading = heading(for: kind)
        let name = item.fixedTitle ?? RowBuilder.title(for: item)
        return DownloadNotice(
            id: noticeID(kind, item: item), kind: kind, title: heading, body: name)
    }

    func heading(for kind: DownloadNotice.Kind) -> String {
        switch kind {
        case .completed:
            return "Download finished"
        case .failed:
            return "Download failed"
        }
    }

    func noticeID(_ kind: DownloadNotice.Kind, item: TrackedDownload) -> String {
        switch kind {
        case .completed:
            return "completed-\(item.id)"
        case .failed:
            return "failed-\(item.id)"
        }
    }

    func remember(_ entry: FinishedDownload) {
        history.removeAll { $0.id == entry.id }
        history.insert(entry, at: 0)
        if history.count > Self.historyLimit {
            history.removeLast(history.count - Self.historyLimit)
        }
        store.saveHistory(history)
    }

    func abandonLiveDownloads() {
        for index in tracked.indices where tracked[index].track {
            tracked[index].track = false
            if tracked[index].state != .complete {
                tracked[index].state = .error
                tracked[index].downloadSpeed = 0
                if tracked[index].errorMessage == nil {
                    tracked[index].errorMessage = "This download stopped when the engine restarted."
                }
            }
        }
    }

    func makeLiveItem(gid: String, prepared: PreparedDownload) -> TrackedDownload {
        TrackedDownload(
            id: gid,
            engineGID: gid,
            track: true,
            outputName: prepared.options["out"] ?? "",
            url: prepared.url,
            detail: prepared.url.absoluteString,
            state: .waiting,
            totalLength: 0,
            completedLength: 0,
            downloadSpeed: 0,
            errorMessage: nil,
            filePath: nil,
            historyID: nil,
            fixedTitle: nil,
            pausable: true
        )
    }

    func acceptedFile(_ files: [URL]) -> String? {
        guard let directory else { return nil }
        for file in files {
            if let resolved = try? DownloadFolderRules.resolveInside(
                root: directory,
                raw: file.path
            ) {
                return resolved
            }
        }
        return nil
    }

    var hasActiveWork: Bool {
        tracked.contains { $0.allowsPause || $0.allowsResume || $0.cancelsLiveVideo }
    }

    func liveGIDs() -> [String] {
        tracked.compactMap { item in
            guard item.track, let gid = item.engineGID else { return nil }
            return gid
        }
    }

    func index(of id: String) -> Int? {
        tracked.firstIndex { $0.id == id }
    }

    func trackedItem(id: String) -> TrackedDownload? {
        guard let index = index(of: id) else { return nil }
        return tracked[index]
    }

    func indexOfLive(_ gid: String) -> Int? {
        tracked.firstIndex { $0.track && $0.engineGID == gid }
    }

    func rebuild() {
        let rows = tracked.map(RowBuilder.make)
        snapshot = SessionSnapshot(
            rows: rows,
            menuRows: MenuBarSummary.items(for: rows),
            menuTitle: MenuBarSummary.title(for: rows),
            downloadDirectoryPath: directory?.path,
            phase: phase,
            message: message,
            notifyOnComplete: settings.notifyOnComplete,
            notifyOnFailure: settings.notifyOnFailure,
            helpers: helpers,
            canAdd: phase == .running && client != nil
        )
    }

    static func acceptedDirectory(_ path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        return try? DownloadFolderRules.acceptRoot(URL(fileURLWithPath: path, isDirectory: true))
    }

    static func historyRows(_ history: [FinishedDownload], root: URL?) -> [TrackedDownload] {
        history.map { entry in
            TrackedDownload(
                id: entry.id,
                engineGID: nil,
                track: false,
                outputName: "",
                url: URL(string: entry.detail),
                detail: entry.detail,
                state: .complete,
                totalLength: entry.totalLength,
                completedLength: entry.totalLength,
                downloadSpeed: 0,
                errorMessage: nil,
                filePath: restoredFile(entry.filePath, root: root),
                historyID: entry.id,
                fixedTitle: entry.title,
                pausable: true
            )
        }
    }

    static func restoredFile(_ path: String?, root: URL?) -> String? {
        guard let path, let root else { return nil }
        return try? DownloadFolderRules.resolveInside(root: root, raw: path)
    }
}
