// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalEngine
@testable import UmbilicalUI

@MainActor
final class DownloadSessionRefreshTests: XCTestCase {
    func testRefreshShowsProgressSpeedAndETA() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("report.bin")
        try Data("hello".utf8).write(to: file)
        try await model.add(
            urlText: "https://example.com/report.bin?token=example", outputName: "", folder: nil)
        let gid = try XCTUnwrap(client.added.isEmpty ? nil : "g1")
        client.statuses[gid] = DownloadStatus(
            gid: gid,
            state: .active,
            totalLength: 2048,
            completedLength: 1024,
            downloadSpeed: 1024,
            files: [file],
            errorMessage: nil
        )
        await model.refresh()
        let row = try XCTUnwrap(model.snapshot.rows.first)
        XCTAssertEqual(row.title, "report.bin")
        XCTAssertEqual(row.stateText, "50%")
        XCTAssertEqual(row.speedText, "1.0 KB/s")
        XCTAssertEqual(row.etaText, "1s")
        XCTAssertEqual(row.sizeText, "1.0 KB of 2.0 KB")
        XCTAssertEqual(row.fraction, 0.5)
        XCTAssertEqual(model.snapshot.menuTitle, "50% 1.0 KB/s")
        XCTAssertEqual(model.snapshot.menuRows.first?.label, "report.bin 50%")
        XCTAssertFalse(row.detail.contains("token:"))
    }

    func testCompletionNotifiesOnceAndHistorySurvivesReload() async throws {
        let store = MemorySettings()
        let session = try await running(store: store)
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("done.bin")
        try Data("x".utf8).write(to: file)
        try await model.add(
            urlText: "https://example.com/done.bin", outputName: "done.bin", folder: nil)
        client.statuses["g1"] = DownloadStatus(
            gid: "g1",
            state: .complete,
            totalLength: 4,
            completedLength: 4,
            downloadSpeed: 0,
            files: [file],
            errorMessage: nil
        )
        await model.refresh()
        let notices = model.takeNotices()
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.kind, .completed)
        XCTAssertEqual(notices.first?.title, "Download finished")
        XCTAssertEqual(notices.first?.body, "done.bin")
        XCTAssertFalse(notices.first?.body.contains("http") == true)
        await model.refresh()
        XCTAssertTrue(model.takeNotices().isEmpty)
        XCTAssertEqual(client.statusCalls.count, 1)
        XCTAssertEqual(model.snapshot.menuTitle, "")
        XCTAssertEqual(store.history.count, 1)

        let revivedFixture = makeSession(store: store)
        let revived = revivedFixture.model
        let revivedEngine = revivedFixture.engine
        let revivedClient = revivedFixture.client
        XCTAssertEqual(revived.snapshot.rows.first?.title, "done.bin")
        XCTAssertEqual(revived.snapshot.rows.first?.isComplete, true)
        try await revived.updateDownloadDirectory(root)
        await revived.refresh()
        XCTAssertTrue(revivedClient.statusCalls.isEmpty)
        XCTAssertEqual(revivedEngine.directories.count, 1)
    }

    func testNoticesCanBeDisabledAndErrorsAreRedacted() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        model.setNotifyOnComplete(false)
        model.setNotifyOnFailure(true)
        try await model.add(urlText: "https://example.com/a.bin", outputName: "a.bin", folder: nil)
        client.statuses["g1"] = DownloadStatus(
            gid: "g1",
            state: .error,
            totalLength: 0,
            completedLength: 0,
            downloadSpeed: 0,
            files: [],
            errorMessage: "token:abcd from the server"
        )
        await model.refresh()
        let failure = model.takeNotices()
        XCTAssertEqual(failure.first?.kind, .failed)
        XCTAssertEqual(failure.first?.body, "a.bin")
        XCTAssertFalse(model.snapshot.rows.first?.errorMessage?.contains("abcd") == true)
        client.statuses["g1"] = DownloadStatus(
            gid: "g1",
            state: .complete,
            totalLength: 1,
            completedLength: 1,
            downloadSpeed: 0,
            files: [],
            errorMessage: nil
        )
        await model.refresh()
        XCTAssertTrue(model.takeNotices().isEmpty)
        XCTAssertEqual(model.snapshot.rows.first?.isComplete, true)
    }

    func testOutsideFilePathIsNotKept() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(urlText: "https://example.com/a.bin", outputName: "a.bin", folder: nil)
        client.statuses["g1"] = DownloadStatus(
            gid: "g1",
            state: .active,
            totalLength: 10,
            completedLength: 1,
            downloadSpeed: 1,
            files: [URL(fileURLWithPath: "/etc/passwd")],
            errorMessage: nil
        )
        await model.refresh()
        XCTAssertNil(model.snapshot.rows.first?.filePath)
        XCTAssertEqual(model.snapshot.rows.first?.title, "a.bin")
    }

    private func running(
        store: MemorySettings = MemorySettings()
    ) async throws -> RunningFixture {
        let root = try makeTempDirectory()
        let client = FakeDownloads()
        let fixture = makeSession(client: client, store: store)
        try await fixture.model.updateDownloadDirectory(root)
        let accepted = URL(
            fileURLWithPath: try XCTUnwrap(fixture.model.snapshot.downloadDirectoryPath),
            isDirectory: true
        )
        return RunningFixture(
            model: fixture.model,
            engine: fixture.engine,
            client: client,
            root: accepted
        )
    }
}
