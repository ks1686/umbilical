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

    func testVideoHandoffDoesNotUseAria2() async throws {
        let session = try await running()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let staged = try ExternalDownload.stage(
            nativeMessage: ["url": "https://example.com/watch", "video": true] as [String: Any],
            downloadRoot: session.root
        )
        XCTAssertEqual(staged.kind, .video)
        let confirmed = try ExternalDownload.confirm(staged, downloadRoot: session.root)
        do {
            try await session.model.addExternal(confirmed)
            XCTFail("expected yt-dlp to be required")
        } catch let error as EngineError {
            guard case .executableMissing("yt-dlp") = error else {
                XCTFail("unexpected \(error)")
                return
            }
        }
        XCTAssertTrue(session.client.added.isEmpty)
        XCTAssertTrue(session.client.torrents.isEmpty)
    }

    func testRemoteMetalinkDoesNotUseAddUri() async throws {
        let session = try await running()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let staged = try ExternalDownload.stage(
            urlText: "http://127.0.0.1/pack.metalink",
            filename: "pack.metalink",
            downloadRoot: session.root
        )
        do {
            try await session.model.addExternal(
                try ExternalDownload.confirm(staged, downloadRoot: session.root)
            )
            XCTFail("expected loopback metalink fetch to be rejected")
        } catch let error as EngineError {
            XCTAssertEqual(error, .torrentRejected("host"))
        }
        XCTAssertTrue(session.client.added.isEmpty)
        XCTAssertTrue(session.client.metalinks.isEmpty)
        XCTAssertTrue(session.client.torrents.isEmpty)
        XCTAssertTrue(session.model.snapshot.rows.isEmpty)
    }

    func testConfirmedFTPIsAdded() async throws {
        let session = try await running()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let staged = try ExternalDownload.stage(
            urlText: "ftp://example.com/a.bin",
            filename: "a.bin",
            downloadRoot: session.root
        )
        let confirmed = try ExternalDownload.confirm(staged, downloadRoot: session.root)
        try await session.model.addExternal(confirmed)
        XCTAssertEqual(session.client.added.first?.url.scheme?.lowercased(), "ftp")
        XCTAssertEqual(session.client.added.first?.options, ["out": "a.bin"])
        let sftp = try ExternalDownload.stage(
            urlText: "sftp://files.example.com/b.bin",
            filename: "b.bin",
            downloadRoot: session.root
        )
        try await session.model.addExternal(
            try ExternalDownload.confirm(sftp, downloadRoot: session.root)
        )
        XCTAssertEqual(session.client.added.last?.url.scheme?.lowercased(), "sftp")
        XCTAssertTrue(session.client.torrents.isEmpty)
    }

    func testDashPrefixedURLNeverReachesTheEngine() async throws {
        let session = try await running()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let poisoned = ConfirmedExternalDownload(
            uri: "--out=evil",
            outputName: nil,
            url: try XCTUnwrap(URL(string: "https://example.com/a.bin")),
            options: [:],
            kind: .download
        )
        do {
            try await session.model.addExternal(poisoned)
            XCTFail("expected a dash-prefixed URL to be rejected")
        } catch let error as EngineError {
            XCTAssertNotNil(error)
        }
        XCTAssertTrue(session.client.added.isEmpty)
        XCTAssertTrue(session.client.torrents.isEmpty)
    }

    func testLocalTorrentGoesToAddTorrent() async throws {
        let session = try await running()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let source = session.root.deletingLastPathComponent().appendingPathComponent(
            "umb-src-\(UUID().uuidString).torrent"
        )
        try sampleTorrentBytes().write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let staged = try ExternalDownload.stage(localFile: source, downloadRoot: session.root)
        let confirmed = try ExternalDownload.confirm(staged, downloadRoot: session.root)
        try await session.model.addExternal(confirmed)
        XCTAssertTrue(session.client.added.isEmpty)
        let recorded = try XCTUnwrap(session.client.torrents.first)
        XCTAssertEqual(recorded.file.path, source.path)
        XCTAssertTrue(recorded.options.isEmpty)
        let copied = session.root.appendingPathComponent(source.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
    }

    func testLocalMetalinkGoesToAddMetalink() async throws {
        let session = try await running(quarantine: NoopQuarantine())
        defer { try? FileManager.default.removeItem(at: session.root) }
        let source = session.root.deletingLastPathComponent().appendingPathComponent(
            "umb-src-\(UUID().uuidString).meta4"
        )
        try sampleMetalinkBytes().write(to: source)
        defer { try? FileManager.default.removeItem(at: source) }
        let staged = try ExternalDownload.stage(localFile: source, downloadRoot: session.root)
        let confirmed = try ExternalDownload.confirm(staged, downloadRoot: session.root)
        try await session.model.addExternal(confirmed)
        XCTAssertTrue(session.client.added.isEmpty)
        XCTAssertTrue(session.client.torrents.isEmpty)
        let recorded = try XCTUnwrap(session.client.metalinks.first)
        XCTAssertEqual(recorded.file.path, source.path)
        XCTAssertEqual(recorded.options["follow-metalink"], "true")
        XCTAssertEqual(session.model.snapshot.rows.count, 1)
        XCTAssertEqual(session.model.snapshot.rows.first?.stateText, "Waiting")
        let copied = session.root.appendingPathComponent(source.lastPathComponent)
        XCTAssertFalse(FileManager.default.fileExists(atPath: copied.path))
    }

    func testRejectedMetalinkNeverReachesAddMetalink() async throws {
        let session = try await running()
        defer { try? FileManager.default.removeItem(at: session.root) }
        let cases: [(String, String)] = [
            ("payload.bin", "file:///tmp/payload.bin"),
            ("payload.bin", "-o"),
            ("../payload.bin", "https://example.com/payload.bin"),
            ("/tmp/payload.bin", "https://example.com/payload.bin")
        ]
        for (name, url) in cases {
            let source = session.root.deletingLastPathComponent().appendingPathComponent(
                "umb-bad-\(UUID().uuidString).meta4"
            )
            try sampleMetalinkBytes(name: name, url: url).write(to: source)
            defer { try? FileManager.default.removeItem(at: source) }
            XCTAssertThrowsError(
                try ExternalDownload.stage(localFile: source, downloadRoot: session.root)
            )
        }
        XCTAssertTrue(session.client.metalinks.isEmpty)
        XCTAssertTrue(session.client.added.isEmpty)
        XCTAssertTrue(session.model.snapshot.rows.isEmpty)
    }

    private func sampleMetalinkBytes(
        name: String = "payload.bin",
        url: String = "https://example.com/payload.bin"
    ) -> Data {
        let escapedName =
            name
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
        let escapedURL =
            url
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<metalink xmlns=\"urn:ietf:params:xml:ns:metalink\">",
            "  <file name=\"\(escapedName)\">",
            "    <url>\(escapedURL)</url>",
            "  </file>",
            "</metalink>",
            ""
        ]
        return Data(lines.joined(separator: "\n").utf8)
    }

    private func sampleTorrentBytes() throws -> Data {
        let header =
            "d8:announce27:http://127.0.0.1:9/announce4:infod6:lengthi4e4:name11:payload.bin"
            + "12:piece lengthi16e6:pieces20:"
        var data = Data(header.utf8)
        let hex = "12dada1fff4d4787ade3333147202c3b443e376f"
        var hash = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            let byte = UInt8(hex[index..<next], radix: 16)!
            hash.append(byte)
            index = next
        }
        data.append(hash)
        data.append(Data("ee".utf8))
        return data
    }

    private func running(
        quarantine: any QuarantineApplying = SystemQuarantine()
    ) async throws -> RunningFixture {
        let root = try makeTempDirectory()
        let fixture = makeSession(quarantine: quarantine)
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
