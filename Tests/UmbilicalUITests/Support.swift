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

final class FakeDownloads: DownloadControlling {
    var nextGID = 1
    var statuses: [String: DownloadStatus] = [:]
    var added: [RecordedAdd] = []
    var paused: [String] = []
    var resumed: [String] = []
    var removed: [String] = []
    var statusCalls: [String] = []
    var failRemove = false
    var statusError: Error?

    func add(url: URL, options: [String: String]) async throws -> String {
        added.append(RecordedAdd(url: url, options: options))
        let gid = "g\(nextGID)"
        nextGID += 1
        statuses[gid] = DownloadStatus(
            gid: gid,
            state: .waiting,
            totalLength: 0,
            completedLength: 0,
            downloadSpeed: 0,
            files: [],
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
        guard let status = statuses[gid] else {
            throw EngineError.transport("missing")
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
    now: Date = Date(timeIntervalSince1970: 1_700_000_000)
) -> SessionFixture {
    let engine = FakeEngine(client: client)
    let model = DownloadSessionModel(
        engine: engine,
        store: store,
        helpers: helpers,
        clock: { now }
    )
    return SessionFixture(model: model, engine: engine, client: client, store: store)
}

func allowlist() -> Set<String> {
    ["out", "select-file", "max-download-limit", "split", "dir"]
}
