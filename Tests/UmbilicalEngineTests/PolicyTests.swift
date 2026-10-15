// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalEngine

final class PolicyTests: XCTestCase {
    func testRenderedSettingsPinSecurityOptions() throws {
        let text = try Aria2Settings.render(
            secret: String(repeating: "ab", count: 32),
            port: 43111,
            downloadDirectory: "/tmp/downloads"
        )
        XCTAssertTrue(text.contains("rpc-secret=\(String(repeating: "ab", count: 32))"))
        XCTAssertTrue(text.contains("rpc-listen-all=false"))
        XCTAssertTrue(text.contains("rpc-allow-origin-all=false"))
        XCTAssertTrue(text.contains("check-certificate=true"))
        XCTAssertTrue(text.contains("seed-time=0"))
        XCTAssertTrue(text.contains("seed-ratio=0.0"))
        XCTAssertTrue(text.contains("max-upload-limit=1K"))
        XCTAssertTrue(text.contains("allow-overwrite=false"))
        XCTAssertTrue(text.contains("check-integrity=true"))
        XCTAssertTrue(text.contains("auto-file-renaming=true"))
        XCTAssertFalse(text.contains("max-upload-limit=0"))
        XCTAssertFalse(text.contains("--rpc-secret"))
    }

    func testHookOptionsAreRejectedBeforeTransport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecordingTransport()
        let client = RPCClient(
            port: 1,
            secret: "secret",
            downloadDirectory: root,
            transport: transport,
            quarantine: RecordingQuarantine()
        )
        let hooks = ["on-download-complete", "on-download-error", "ON-DOWNLOAD-START"]
        for hook in hooks {
            do {
                _ = try await client.add(
                    url: try testURL("https://example.com/file"),
                    options: [hook: "id"]
                )
                XCTFail("expected \(hook) to be rejected")
            } catch let error as EngineError {
                guard case .hookRejected = error else {
                    XCTFail("unexpected error \(error)")
                    return
                }
            }
        }
        XCTAssertTrue(transport.methods.isEmpty)
    }

    func testDisallowedOptionsAreRejected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecordingTransport()
        let client = RPCClient(
            port: 1,
            secret: "secret",
            downloadDirectory: root,
            transport: transport,
            quarantine: RecordingQuarantine()
        )
        let rejected = ["check-certificate", "rpc-secret", "log", "always-resume"]
        for name in rejected {
            do {
                try await client.changeGlobalOption([name: "false"])
                XCTFail("expected \(name) to be rejected")
            } catch let error as EngineError {
                guard case .optionRejected = error else {
                    XCTFail("unexpected error \(error)")
                    return
                }
            }
        }
        XCTAssertTrue(transport.methods.isEmpty)
    }

    func testDirectoriesOutsideTheDownloadFolderAreRejected() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("downloads", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        let sibling = parent.appendingPathComponent("downloads-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertThrowsError(try DownloadPath.resolveInside(root: root, raw: outside.path))
        XCTAssertThrowsError(try DownloadPath.resolveInside(root: root, raw: sibling.path))
        XCTAssertThrowsError(try DownloadPath.resolveInside(root: root, raw: "../outside"))
        XCTAssertThrowsError(try DownloadPath.resolveInside(root: root, raw: link.path))
        XCTAssertThrowsError(try DownloadPath.resolveInside(root: root, raw: "escape"))
        XCTAssertNoThrow(try DownloadPath.resolveInside(root: root, raw: root.path))
        XCTAssertNoThrow(try DownloadPath.resolveInside(root: root, raw: "nested/child"))
    }

    func testOutputNamesAndSchemesAreRejected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecordingTransport()
        let client = RPCClient(
            port: 1,
            secret: "secret",
            downloadDirectory: root,
            transport: transport,
            quarantine: RecordingQuarantine()
        )
        do {
            _ = try await client.add(url: try testURL("file:///tmp/x"))
            XCTFail("expected file URL to be rejected")
        } catch let error as EngineError {
            guard case .schemeRejected = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        do {
            let userInfo = try testURL("https://user:secret@example.com/a")
            _ = try await client.add(url: userInfo)
            XCTFail("expected userinfo to be rejected")
        } catch let error as EngineError {
            guard case .schemeRejected = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        do {
            _ = try await client.add(
                url: try testURL("https://example.com/a"),
                options: ["out": "../x"]
            )
            XCTFail("expected output name to be rejected")
        } catch let error as EngineError {
            guard case .outputNameRejected = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        XCTAssertTrue(transport.methods.isEmpty)
    }

    func testAllowedOptionsReachTheTransport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let transport = RecordingTransport()
        let client = RPCClient(
            port: 1,
            secret: "abc",
            downloadDirectory: root,
            transport: transport,
            quarantine: RecordingQuarantine()
        )
        _ = try await client.add(
            url: try testURL("https://example.com/file.bin"),
            options: [
                "out": "file.bin",
                "split": "1",
                "max-download-limit": "1M",
                "select-file": "1,2",
                "dir": root.path
            ]
        )
        XCTAssertEqual(transport.methods, ["aria2.addUri"])
    }

    func testTorrentAndMetalinkRejectHooksFirst() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let client = RPCClient(
            port: 1,
            secret: "abc",
            downloadDirectory: root,
            transport: RecordingTransport(),
            quarantine: RecordingQuarantine()
        )
        let file = root.appendingPathComponent("item.bin")
        do {
            _ = try await client.addTorrent(file: file, options: ["on-download-complete": "id"])
            XCTFail("expected hook rejection")
        } catch let error as EngineError {
            guard case .hookRejected = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
        do {
            _ = try await client.addMetalink(file: file, options: ["dir": "/tmp"])
            XCTFail("expected directory rejection")
        } catch let error as EngineError {
            guard case .directoryRejected = error else {
                XCTFail("unexpected error \(error)")
                return
            }
        }
    }
}
