// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalEngine
@testable import UmbilicalUI

@MainActor
final class ExternalDownloadSessionTests: XCTestCase {
    func testHandoffDoesNotStartUntilItIsConfirmed() async throws {
        let session = try await running()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let message: [String: Any] = [
            "url": "https://example.com/clip.bin",
            "filename": "clip.bin"
        ]
        let staged = try ExternalDownload.stage(nativeMessage: message, downloadRoot: session.root)
        XCTAssertTrue(session.client.added.isEmpty)
        let confirmed = try ExternalDownload.confirm(staged, downloadRoot: session.root)
        XCTAssertTrue(session.client.added.isEmpty)
        try await session.model.addExternal(confirmed)
        let added = try XCTUnwrap(session.client.added.first)
        XCTAssertEqual(added.options, ["out": "clip.bin"])
        XCTAssertEqual(added.url.scheme?.lowercased(), "https")
        XCTAssertEqual(session.model.snapshot.rows.count, 1)
    }

    func testConfirmedMagnetIsAddedWithNoExtraOptions() async throws {
        let session = try await running()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let hash = String(repeating: "ab", count: 20)
        let raw = "magnet:?xt=urn:btih:\(hash)"
        let staged = try ExternalDownload.stage(
            urlText: raw, filename: nil, downloadRoot: session.root)
        let confirmed = try ExternalDownload.confirm(staged, downloadRoot: session.root)
        try await session.model.addExternal(confirmed)
        let added = try XCTUnwrap(session.client.added.first)
        XCTAssertEqual(try MagnetLink.canonical(added.url), staged.uri)
        XCTAssertTrue(added.options.isEmpty)
    }

    func testPoisonedOptionsAreRebuiltFromTheURLAndName() async throws {
        let session = try await running()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let url = try XCTUnwrap(URL(string: "https://example.com/a.bin"))
        let poisoned = ConfirmedExternalDownload(
            uri: "https://example.com/a.bin",
            outputName: "a.bin",
            url: url,
            options: [
                "out": "sneaky.bin",
                "cookie": "a=b",
                "header": "Bearer",
                "dir": "/tmp",
                "on-download-complete": "id"
            ]
        )
        try await session.model.addExternal(poisoned)
        XCTAssertEqual(session.client.added.first?.options, ["out": "a.bin"])

        let nameless = ConfirmedExternalDownload(
            uri: "https://example.com/b.bin",
            outputName: nil,
            url: try XCTUnwrap(URL(string: "https://example.com/b.bin")),
            options: ["out": "sneaky.bin", "cookie": "a"]
        )
        try await session.model.addExternal(nameless)
        XCTAssertEqual(session.client.added.last?.options, [:])
    }

    func testRejectedHandoffDoesNotReachTheEngine() async throws {
        let session = try await running()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let badName = ConfirmedExternalDownload(
            uri: "https://example.com/a.bin",
            outputName: "../x",
            url: try XCTUnwrap(URL(string: "https://example.com/a.bin")),
            options: ["out": "ok.bin"]
        )
        do {
            try await session.model.addExternal(badName)
            XCTFail("expected the file name to be rejected")
        } catch let error as EngineError {
            guard case .outputNameRejected = error else {
                XCTFail("unexpected \(error)")
                return
            }
        }
        let fileURL = ConfirmedExternalDownload(
            uri: "file:///tmp/x",
            outputName: nil,
            url: try XCTUnwrap(URL(string: "file:///tmp/x")),
            options: [:]
        )
        do {
            try await session.model.addExternal(fileURL)
            XCTFail("expected file to be rejected")
        } catch let error as EngineError {
            guard case .schemeRejected("file") = error else {
                XCTFail("unexpected \(error)")
                return
            }
        }
        XCTAssertTrue(session.client.added.isEmpty)
        XCTAssertTrue(session.model.snapshot.rows.isEmpty)
    }

    private func running() async throws -> RunningFixture {
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
