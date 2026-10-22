// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalEngine
@testable import UmbilicalUI

struct RecordedAdd: Equatable {
    var url: URL
    var options: [String: String]
}

struct RecordedTorrent: Equatable {
    var file: URL
    var options: [String: String]
}

struct RecordedMetalink: Equatable {
    var file: URL
    var options: [String: String]
}

final class FakeDownloads: DownloadControlling {
    var nextGID = 1
    var statuses: [String: DownloadStatus] = [:]
    var added: [RecordedAdd] = []
    var torrents: [RecordedTorrent] = []
    var metalinks: [RecordedMetalink] = []
    var filesByGID: [String: [URL]] = [:]
    var paused: [String] = []
    var resumed: [String] = []
    var removed: [String] = []
    var statusCalls: [String] = []
    var failRemove = false
    var statusError: Error?
    var onFiles: (() async -> Void)?
    var controlPathOnRemovedStatus: [String: URL] = [:]

    func add(url: URL, options: [String: String]) async throws -> String {
        added.append(RecordedAdd(url: url, options: options))
        return register(url: url)
    }

    func addTorrent(file: URL, options: [String: String]) async throws -> String {
        torrents.append(RecordedTorrent(file: file, options: options))
        return register(url: file)
    }

    func addMetalink(file: URL, options: [String: String]) async throws -> [String] {
        metalinks.append(RecordedMetalink(file: file, options: options))
        return [register(url: file)]
    }

    func files(gid: String) async throws -> [URL] {
        if let onFiles {
            await onFiles()
        }
        if let listed = filesByGID[gid] {
            return listed
        }
        return statuses[gid]?.files ?? []
    }

    private func register(url: URL) -> String {
        let gid = "g\(nextGID)"
        nextGID += 1
        statuses[gid] = DownloadStatus(
            gid: gid,
            state: .waiting,
            totalLength: 0,
            completedLength: 0,
            downloadSpeed: 0,
            files: url.isFileURL ? [url] : [],
            errorMessage: nil
        )
        return gid
    }

    func pause(gid: String) async throws {
        paused.append(gid)
    }

    func resume(gid: String) async throws {
        resumed.append(gid)
    }

    func remove(gid: String) async throws {
        if failRemove {
            throw EngineError.transport("remove")
        }
        removed.append(gid)
    }

    func status(gid: String) async throws -> DownloadStatus {
        statusCalls.append(gid)
        if let statusError {
            throw statusError
        }
        if removed.contains(gid) {
            if let control = controlPathOnRemovedStatus.removeValue(forKey: gid) {
                try? Data("ctrl".utf8).write(to: control)
            }
        }
        guard let status = statuses[gid] else {
            throw EngineError.transport("missing")
        }
        if removed.contains(gid) {
            return DownloadStatus(
                gid: status.gid,
                state: .removed,
                totalLength: status.totalLength,
                completedLength: status.completedLength,
                downloadSpeed: status.downloadSpeed,
                files: status.files,
                errorMessage: status.errorMessage
            )
        }
        return status
    }
}

final class FakeEngine: EngineLaunching {
    let client: FakeDownloads
    var directories: [URL] = []
    var stopCount = 0

    init(client: FakeDownloads) {
        self.client = client
    }

    func start(downloadDirectory: URL) async throws -> any DownloadControlling {
        directories.append(downloadDirectory)
        return client
    }

    func stop() {
        stopCount += 1
    }
}

final class NoopQuarantine: QuarantineApplying {
    func markDownloaded(file _: URL) throws {}
}

final class MemorySettings: SettingsStoring {
    var settings = AppSettings()
    var history: [FinishedDownload] = []

    func loadSettings() -> AppSettings { settings }
    func saveSettings(_ settings: AppSettings) { self.settings = settings }
    func loadHistory() -> [FinishedDownload] { history }
    func saveHistory(_ history: [FinishedDownload]) { self.history = history }
}

func makeTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("umb-ui-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct SessionFixture {
    var model: DownloadSessionModel
    var engine: FakeEngine
    var client: FakeDownloads
    var store: MemorySettings
}

struct RunningFixture {
    var model: DownloadSessionModel
    var engine: FakeEngine
    var client: FakeDownloads
    var root: URL
}

@MainActor
func makeSession(
    client: FakeDownloads = FakeDownloads(),
    store: MemorySettings = MemorySettings(),
    helpers: HelperStatus = HelperStatus(aria2Found: true, watchFound: true),
    video: VideoHelpers = VideoHelpers(ytDlp: nil, watch: nil),
    quarantine: any QuarantineApplying = SystemQuarantine(),
    now: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> SessionFixture {
    let engine = FakeEngine(client: client)
    let model = DownloadSessionModel(
        engine: engine,
        store: store,
        helpers: helpers,
        video: video,
        quarantine: quarantine,
        clock: { now }
    )
    return SessionFixture(model: model, engine: engine, client: client, store: store)
}

func allowlist() -> Set<String> {
    ["out", "select-file", "max-download-limit", "split", "dir"]
}
