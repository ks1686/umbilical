// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalEngine

final class MetalinkDocumentTests: XCTestCase {
    func testAcceptedMetalink4ParsesNamesAndMirrors() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let parsed = try MetalinkDocument.parse(
            metalink4(name: "payload.bin", url: "https://example.com/payload.bin"),
            downloadRoot: root
        )
        XCTAssertEqual(parsed.files.count, 1)
        XCTAssertEqual(parsed.files.first?.name, "payload.bin")
        XCTAssertEqual(parsed.files.first?.urls, ["https://example.com/payload.bin"])
    }

    func testBadMirrorSchemeIsRejected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(
            try MetalinkDocument.parse(
                metalink4(name: "payload.bin", url: "file:///tmp/payload.bin"),
                downloadRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? EngineError, .schemeRejected("file"))
        }
        XCTAssertThrowsError(
            try MetalinkDocument.parse(
                metalink4(name: "payload.bin", url: "javascript:alert(1)"),
                downloadRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? EngineError, .schemeRejected("javascript"))
        }
        XCTAssertThrowsError(
            try MetalinkDocument.parse(
                metalink4(name: "payload.bin", url: "data:text/plain,hi"),
                downloadRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? EngineError, .schemeRejected("data"))
        }
    }

    func testOptionLookingURLIsRejected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(
            try MetalinkDocument.parse(
                metalink4(name: "payload.bin", url: "-o"),
                downloadRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? EngineError, .schemeRejected("option"))
        }
    }

    func testParentDirectoryNameIsRejected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(
            try MetalinkDocument.parse(
                metalink4(name: "../payload.bin", url: "https://example.com/payload.bin"),
                downloadRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? EngineError, .outputNameRejected("../payload.bin"))
        }
    }

    func testAbsoluteNameIsRejected() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(
            try MetalinkDocument.parse(
                metalink4(name: "/tmp/payload.bin", url: "https://example.com/payload.bin"),
                downloadRoot: root
            )
        ) { error in
            XCTAssertEqual(error as? EngineError, .outputNameRejected("/tmp/payload.bin"))
        }
    }
}

final class MetalinkRPCTests: XCTestCase {
    func testAddMetalinkSendsBase64AndFollows() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = metalink4(name: "payload.bin", url: "https://example.com/payload.bin")
        let file = root.appendingPathComponent("list.meta4")
        try bytes.write(to: file)
        let transport = RecordingTransport()
        let client = RPCClient(
            port: 1,
            secret: "secret",
            downloadDirectory: root,
            transport: transport,
            quarantine: RecordingQuarantine()
        )
        let gids = try await client.addMetalink(file: file)
        XCTAssertEqual(gids, ["gid"])
        XCTAssertEqual(transport.methods, ["aria2.addMetalink"])
        let params = try XCTUnwrap(transport.parameters.first)
        XCTAssertEqual(params[1] as? String, bytes.base64EncodedString())
        let options = try XCTUnwrap(params[2] as? [String: String])
        XCTAssertEqual(options["follow-metalink"], "true")
    }

    func testRejectedMetalinkNeverReachesTheTransport() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let cases: [(Data, String)] = [
            (metalink4(name: "payload.bin", url: "file:///tmp/x"), "scheme"),
            (metalink4(name: "payload.bin", url: "-o"), "option"),
            (metalink4(name: "../x", url: "https://example.com/x"), "parent"),
            (metalink4(name: "/tmp/x", url: "https://example.com/x"), "absolute")
        ]
        for (bytes, label) in cases {
            let file = root.appendingPathComponent("bad-\(label).meta4")
            try bytes.write(to: file)
            let transport = RecordingTransport()
            let client = RPCClient(
                port: 1,
                secret: "secret",
                downloadDirectory: root,
                transport: transport,
                quarantine: RecordingQuarantine()
            )
            do {
                _ = try await client.addMetalink(file: file)
                XCTFail("expected \(label) to be rejected")
            } catch is EngineError {
                XCTAssertTrue(transport.methods.isEmpty, label)
            }
        }
    }
}

func metalink4(name: String, url: String) -> Data {
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
