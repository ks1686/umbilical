// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalEngine
@testable import UmbilicalUI

@MainActor
final class DownloadSessionControlTests: XCTestCase {
    func testPauseResumeAndRemove() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(urlText: "https://example.com/a.bin", outputName: "a.bin", folder: nil)
        await model.pause(id: "g1")
        XCTAssertEqual(client.paused, ["g1"])
        XCTAssertEqual(model.snapshot.rows.first?.stateText, "Paused")
        XCTAssertEqual(model.snapshot.rows.first?.canResume, true)
        XCTAssertEqual(model.snapshot.menuTitle, "umb")
        XCTAssertEqual(model.snapshot.menuRows.first?.label, "a.bin Paused")
        await model.resume(id: "g1")
        XCTAssertEqual(client.resumed, ["g1"])
        XCTAssertEqual(model.snapshot.rows.first?.stateText, "Waiting")
        await model.remove(id: "g1")
        XCTAssertEqual(client.removed, ["g1"])
        XCTAssertTrue(model.snapshot.rows.isEmpty)
    }

    func testFailedRemoveKeepsTheRow() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(urlText: "https://example.com/a.bin", outputName: "a.bin", folder: nil)
        client.failRemove = true
        await model.remove(id: "g1")
        XCTAssertEqual(model.snapshot.rows.count, 1)
        XCTAssertEqual(model.snapshot.message, "transport error: remove")
        await model.refresh()
        XCTAssertEqual(model.snapshot.message, "transport error: remove")
    }

    func testRefreshClearsItsOwnErrorAndRemovedRowsLeaveLocally() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(urlText: "https://example.com/a.bin", outputName: "a.bin", folder: nil)
        client.statusError = EngineError.transport("status")
        await model.refresh()
        XCTAssertEqual(model.snapshot.message, "transport error: status")
        client.statusError = nil
        await model.refresh()
        XCTAssertNil(model.snapshot.message)
        client.statuses["g1"] = DownloadStatus(
            gid: "g1",
            state: .removed,
            totalLength: 0,
            completedLength: 0,
            downloadSpeed: 0,
            files: [],
            errorMessage: nil
        )
        await model.refresh()
        XCTAssertEqual(model.snapshot.rows.first?.canRemove, true)
        await model.remove(id: "g1")
        XCTAssertTrue(client.removed.isEmpty)
        XCTAssertTrue(model.snapshot.rows.isEmpty)
    }

    func testRemovingAFinishedDownloadSkipsRPC() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(urlText: "https://example.com/a.bin", outputName: "a.bin", folder: nil)
        client.statuses["g1"] = DownloadStatus(
            gid: "g1",
            state: .complete,
            totalLength: 8,
            completedLength: 8,
            downloadSpeed: 0,
            files: [],
            errorMessage: nil
        )
        await model.refresh()
        XCTAssertEqual(model.takeNotices().count, 1)
        await model.remove(id: model.snapshot.rows[0].id)
        XCTAssertTrue(client.removed.isEmpty)
        XCTAssertTrue(model.snapshot.rows.isEmpty)
    }

    func testTwoActiveDownloadsShareTheMenuTitle() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(urlText: "https://example.com/a.bin", outputName: "a.bin", folder: nil)
        try await model.add(urlText: "https://example.com/b.bin", outputName: "b.bin", folder: nil)
        for gid in ["g1", "g2"] {
            client.statuses[gid] = DownloadStatus(
                gid: gid,
                state: .active,
                totalLength: 100,
                completedLength: 10,
                downloadSpeed: 1024,
                files: [],
                errorMessage: nil
            )
        }
        await model.refresh()
        XCTAssertEqual(model.snapshot.menuTitle, "2 2.0 KB/s")
        XCTAssertEqual(model.snapshot.menuRows.count, 2)
    }

    func testIndeterminateDownloadHasNoETA() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(urlText: "https://example.com/a.bin", outputName: "", folder: nil)
        client.statuses["g1"] = DownloadStatus(
            gid: "g1",
            state: .active,
            totalLength: 0,
            completedLength: 0,
            downloadSpeed: 0,
            files: [],
            errorMessage: nil
        )
        await model.refresh()
        let row = try XCTUnwrap(model.snapshot.rows.first)
        XCTAssertNil(row.fraction)
        XCTAssertTrue(row.showsIndeterminateProgress)
        XCTAssertEqual(row.stateText, "Starting")
        XCTAssertEqual(row.etaText, "")
        XCTAssertEqual(model.snapshot.menuTitle, "1 0 B/s")
    }

    private func running() async throws -> RunningFixture {
        let root = try makeTempDirectory()
        let client = FakeDownloads()
        let fixture = makeSession(client: client)
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
