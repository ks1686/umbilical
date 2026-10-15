// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalEngine
import XCTest

@testable import UmbilicalUI

@MainActor
final class DownloadSessionModelTests: XCTestCase {
    func testStartRequiresAFolderAndSkipsTheEngine() async {
        let fixture = makeSession()
        let model = fixture.model
        let engine = fixture.engine
        XCTAssertEqual(model.snapshot.phase, .needsFolder)
        XCTAssertEqual(model.snapshot.menuTitle, "umb")
        XCTAssertFalse(model.snapshot.canAdd)
        await model.start()
        XCTAssertTrue(engine.directories.isEmpty)
        XCTAssertEqual(model.snapshot.phase, .needsFolder)
    }

    func testMissingHelpersDoNotLaunch() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeSession(
            helpers: HelperStatus(aria2Found: false, watchFound: true)
        )
        let model = fixture.model
        let engine = fixture.engine
        try await model.updateDownloadDirectory(root)
        XCTAssertTrue(engine.directories.isEmpty)
        XCTAssertEqual(model.snapshot.phase, .failed)
        XCTAssertTrue(model.snapshot.message?.contains("Missing aria2c.") == true)
        XCTAssertFalse(model.snapshot.message?.contains("Missing aria2c and umb-watch") == true)
        XCTAssertEqual(model.snapshot.downloadDirectoryPath?.isEmpty, false)
    }

    func testAddRejectsSchemesNamesAndOutsideFolders() async throws {
        let session = try await runningSession()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-umb")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let rejected = [
            "magnet:?xt=urn:btih:abcd",
            "file:///tmp/x",
            "javascript:alert(1)",
            "https://user:pw@example.com/a",
            "",
            "https://example.com/a b"
        ]
        for url in rejected {
            do {
                try await model.add(urlText: url, outputName: "", folder: nil)
                XCTFail("expected \(url) to be rejected")
            } catch {
                XCTAssertFalse(DownloadMessage.text(for: error).isEmpty)
            }
        }
        do {
            try await model.add(
                urlText: "https://example.com/a.bin",
                outputName: "../a.bin",
                folder: nil
            )
            XCTFail("expected the output name to be rejected")
        } catch let error as EngineError {
            guard case .outputNameRejected = error else {
                XCTFail("unexpected \(error)")
                return
            }
        }
        do {
            _ = try model.checkedChildFolder(outside)
            XCTFail("expected the outside folder to be rejected")
        } catch let error as EngineError {
            guard case .directoryRejected = error else {
                XCTFail("unexpected \(error)")
                return
            }
        }
        XCTAssertTrue(client.added.isEmpty)
        XCTAssertTrue(model.snapshot.rows.isEmpty)
    }

    func testAddSendsOnlyAllowlistedOptionsInsideTheFolder() async throws {
        let session = try await runningSession()
        let model = session.model
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try await model.add(
            urlText: "  https://example.com/a.bin  ",
            outputName: " report.bin ",
            folder: child
        )
        let recorded = try XCTUnwrap(client.added.first)
        XCTAssertEqual(recorded.url.absoluteString, "https://example.com/a.bin")
        XCTAssertEqual(recorded.options["out"], "report.bin")
        let dir = try XCTUnwrap(recorded.options["dir"])
        XCTAssertNoThrow(try DownloadFolderRules.resolveInside(root: root, raw: dir))
        XCTAssertTrue(dir.hasSuffix("/nested"))
        XCTAssertTrue(Set(recorded.options.keys).isSubset(of: allowlist()))
        XCTAssertFalse(recorded.options.keys.contains { $0.lowercased().hasPrefix("on-") })
        XCTAssertEqual(model.snapshot.rows.first?.title, "report.bin")
        XCTAssertEqual(model.snapshot.rows.first?.stateText, "Waiting")
        XCTAssertEqual(model.snapshot.canAdd, true)
    }

    func testSameFolderDoesNotRestartAndActiveWorkBlocksAChange() async throws {
        let session = try await runningSession()
        let model = session.model
        let engine = session.engine
        let client = session.client
        let root = session.root
        defer { try? FileManager.default.removeItem(at: root) }
        let path = try XCTUnwrap(model.snapshot.downloadDirectoryPath)
        try await model.updateDownloadDirectory(URL(fileURLWithPath: path, isDirectory: true))
        XCTAssertEqual(engine.directories.count, 1)
        try await model.add(urlText: "https://example.com/a.bin", outputName: "", folder: nil)
        let other = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: other) }
        do {
            try await model.updateDownloadDirectory(other)
            XCTFail("expected the folder change to be blocked")
        } catch let error as SessionError {
            XCTAssertEqual(error, .folderChangeBlocked)
        }
        XCTAssertEqual(model.snapshot.downloadDirectoryPath, path)
        XCTAssertEqual(engine.directories.count, 1)
        XCTAssertEqual(client.added.count, 1)
    }

    private func runningSession() async throws -> RunningFixture {
        let root = try makeTempDirectory()
        let fixture = makeSession()
        try await fixture.model.updateDownloadDirectory(root)
        let accepted = URL(
            fileURLWithPath: try XCTUnwrap(fixture.model.snapshot.downloadDirectoryPath),
            isDirectory: true
        )
        return RunningFixture(
            model: fixture.model,
            engine: fixture.engine,
            client: fixture.client,
            root: accepted
        )
    }
}
