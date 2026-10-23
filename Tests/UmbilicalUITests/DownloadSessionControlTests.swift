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
        XCTAssertEqual(model.snapshot.rows.first?.showsPauseResume, true)
        XCTAssertEqual(model.snapshot.menuTitle, "")
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
}

@MainActor
final class DownloadSessionRemoveTests: XCTestCase {
    func testRemoveDeletesAControlFileRewrittenWhenTheGIDIsReleased() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(
            urlText: "https://example.com/10Gb.dat",
            outputName: "10Gb.dat",
            folder: nil
        )
        let partial = root.appendingPathComponent("10Gb.dat")
        try Data("partial".utf8).write(to: partial)
        let control = URL(fileURLWithPath: partial.path + ".aria2")
        client.filesByGID["g1"] = [partial]
        client.controlPathOnRemovedStatus["g1"] = control
        await model.remove(id: "g1")
        XCTAssertEqual(client.removed, ["g1"])
        XCTAssertNil(client.controlPathOnRemovedStatus["g1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.path))
        XCTAssertTrue(model.snapshot.rows.isEmpty)
    }

    func testRemoveOfARenamedDownloadLeavesAPreexistingFile() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(
            urlText: "https://example.com/10Gb.dat",
            outputName: "10Gb.dat",
            folder: nil
        )
        let finished = root.appendingPathComponent("10Gb.dat")
        try Data("done".utf8).write(to: finished)
        let renamed = root.appendingPathComponent("10Gb.1.dat")
        try Data("partial".utf8).write(to: renamed)
        let control = URL(fileURLWithPath: renamed.path + ".aria2")
        try Data("ctrl".utf8).write(to: control)
        client.filesByGID["g1"] = [renamed]
        client.statuses["g1"] = DownloadStatus(
            gid: "g1",
            state: .active,
            totalLength: 7,
            completedLength: 3,
            downloadSpeed: 1,
            files: [renamed],
            errorMessage: nil
        )
        await model.refresh()
        await model.remove(id: "g1")
        XCTAssertEqual(client.removed, ["g1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path))
        XCTAssertEqual(try String(contentsOf: finished, encoding: .utf8), "done")
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.path))
        XCTAssertTrue(model.snapshot.rows.isEmpty)
    }

    func testRemovingAnUnfinishedDownloadDeletesItsPartialFile() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(urlText: "https://example.com/a.bin", outputName: "a.bin", folder: nil)
        let partial = root.appendingPathComponent("a.bin")
        try Data("partial".utf8).write(to: partial)
        let control = URL(fileURLWithPath: partial.path + ".aria2")
        try Data("ctrl".utf8).write(to: control)
        client.filesByGID["g1"] = [partial]
        await model.remove(id: "g1")
        XCTAssertEqual(client.removed, ["g1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: control.path))
        XCTAssertTrue(model.snapshot.rows.isEmpty)
    }

    func testRemovingACompleteDownloadLeavesTheFile() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(urlText: "https://example.com/a.bin", outputName: "a.bin", folder: nil)
        let finished = root.appendingPathComponent("a.bin")
        try Data("done".utf8).write(to: finished)
        client.filesByGID["g1"] = [finished]
        client.statuses["g1"] = DownloadStatus(
            gid: "g1",
            state: .complete,
            totalLength: 4,
            completedLength: 4,
            downloadSpeed: 0,
            files: [finished],
            errorMessage: nil
        )
        await model.refresh()
        let row = try XCTUnwrap(model.snapshot.rows.first)
        await model.remove(id: row.id)
        XCTAssertTrue(client.removed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: finished.path))
        XCTAssertTrue(model.snapshot.rows.isEmpty)
    }

    func testRemoveRefusesAnOutsideSymlinkAndAParentPath() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(urlText: "https://example.com/a.bin", outputName: "a.bin", folder: nil)
        let outside = root.deletingLastPathComponent().appendingPathComponent(
            "umb-secret-\(UUID().uuidString)"
        )
        try Data("secret".utf8).write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        let link = root.appendingPathComponent("escape.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        client.filesByGID["g1"] = [link]
        await model.remove(id: "g1")
        XCTAssertEqual(client.removed, ["g1"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))

        try await model.add(urlText: "https://example.com/b.bin", outputName: "b.bin", folder: nil)
        let parentPath = root.appendingPathComponent("..").appendingPathComponent(
            outside.lastPathComponent
        )
        client.filesByGID["g2"] = [parentPath]
        await model.remove(id: "g2")
        XCTAssertEqual(client.removed, ["g1", "g2"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
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
        let finished = try XCTUnwrap(model.snapshot.rows.first)
        XCTAssertFalse(finished.showsPauseResume)
        await model.remove(id: finished.id)
        XCTAssertTrue(client.removed.isEmpty)
        XCTAssertTrue(model.snapshot.rows.isEmpty)
    }

    func testRemoveLooksUpTheRowByIdAfterWaiting() async throws {
        let session = try await running()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        try await model.add(
            urlText: "https://example.com/keep.bin",
            outputName: "keep.bin",
            folder: nil
        )
        try await model.add(
            urlText: "https://example.com/drop.bin",
            outputName: "drop.bin",
            folder: nil
        )
        XCTAssertEqual(model.snapshot.rows.map(\.id), ["g2", "g1"])
        client.onFiles = {
            do {
                try await model.add(
                    urlText: "https://example.com/new.bin",
                    outputName: "new.bin",
                    folder: nil
                )
            } catch {
                XCTFail("insert during files failed: \(error)")
            }
        }
        await model.remove(id: "g2")
        XCTAssertEqual(client.removed, ["g2"])
        XCTAssertEqual(model.snapshot.rows.map(\.id), ["g3", "g1"])
        XCTAssertEqual(model.snapshot.rows.map(\.title), ["new.bin", "keep.bin"])
    }
}

@MainActor
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
