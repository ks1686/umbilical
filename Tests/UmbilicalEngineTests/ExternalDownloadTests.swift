// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalEngine

final class ExternalDownloadTests: XCTestCase {
    func testHTTPAndHTTPSRoundTripThroughTheOpenURL() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let message: [String: Any] = [
            "url": " HTTPS://example.com/a.bin?x=1&y=2#part ",
            "filename": " a.bin "
        ]
        let staged = try ExternalDownload.stage(nativeMessage: message, downloadRoot: root)
        XCTAssertEqual(staged.outputName, "a.bin")
        XCTAssertEqual(staged.options, ["out": "a.bin"])
        XCTAssertEqual(staged.url.scheme?.lowercased(), "https")
        let open = try ExternalDownload.openURL(for: staged, downloadRoot: root)
        let again = try ExternalDownload.stage(openURL: open, downloadRoot: root)
        XCTAssertEqual(again.uri, staged.uri)
        XCTAssertEqual(again.outputName, "a.bin")
        let names = try queryNames(open)
        XCTAssertEqual(names, ["url", "filename"])
        let confirmed = try ExternalDownload.confirm(again, downloadRoot: root)
        XCTAssertEqual(confirmed.options, ["out": "a.bin"])
        XCTAssertNoThrow(try RPCOptionPolicy.validate(confirmed.options, downloadRoot: root))

        let plain: [String: String] = ["url": "http://example.com/file"]
        let noName = try ExternalDownload.stage(nativeMessage: plain, downloadRoot: root)
        XCTAssertNil(noName.outputName)
        XCTAssertTrue(noName.options.isEmpty)
        let confirmedPlain = try ExternalDownload.confirm(noName, downloadRoot: root)
        XCTAssertTrue(confirmedPlain.options.isEmpty)
    }

    func testMagnetCanonicalizesAndRoundTrips() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = String(repeating: "ab", count: 20)
        let raw = "magnet:?xt=urn:btih:\(hash.uppercased())&tr=http://127.0.0.1:9/announce"
        let staged = try ExternalDownload.stage(
            urlText: raw,
            filename: "   ",
            downloadRoot: root
        )
        let canonical = try MagnetLink.canonical(URL(string: raw)!)
        XCTAssertEqual(staged.uri, canonical)
        XCTAssertEqual(try MagnetLink.canonical(staged.url), canonical)
        XCTAssertNil(staged.outputName)
        let open = try ExternalDownload.openURL(for: staged, downloadRoot: root)
        let again = try ExternalDownload.stage(openURL: open, downloadRoot: root)
        XCTAssertEqual(again.uri, canonical)
        XCTAssertTrue(again.options.isEmpty)
        let confirmed = try ExternalDownload.confirm(again, downloadRoot: root)
        XCTAssertEqual(confirmed.options, [:])
        XCTAssertEqual(try queryNames(open), ["url"])
    }

    func testRejectedSchemesUserinfoAndNames() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rejected = [
            "file:///tmp/x": EngineError.schemeRejected("file"),
            "javascript:alert(1)": EngineError.schemeRejected("javascript"),
            "data:text/plain,hi": EngineError.schemeRejected("data"),
            "ftp://example.com/a": EngineError.schemeRejected("ftp"),
            "https://user:secret@example.com/a": EngineError.schemeRejected("userinfo"),
            "": EngineError.schemeRejected("empty"),
            "https://example.com/a b": EngineError.schemeRejected("whitespace")
        ]
        for (text, expected) in rejected {
            XCTAssertThrowsError(
                try ExternalDownload.stage(urlText: text, filename: nil, downloadRoot: root)
            ) { error in
                XCTAssertEqual(error as? EngineError, expected, text)
            }
        }
        let badNames = [
            "../x", "/tmp/x", "a/b", "a\\b", ".", "..", String(repeating: "a", count: 256)
        ]
        for name in badNames {
            XCTAssertThrowsError(
                try ExternalDownload.stage(
                    urlText: "https://example.com/a.bin",
                    filename: name,
                    downloadRoot: root
                )
            ) { error in
                guard case EngineError.outputNameRejected = error else {
                    return XCTFail("\(name) -> \(error)")
                }
            }
        }
    }

    func testExtraFieldsAndNonStringsAreRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = "https://example.com/a.bin"
        let forbidden = [
            "cookie",
            "cookies",
            "header",
            "headers",
            "referrer",
            "options",
            "dir",
            "out",
            "select-file",
            "on-download-complete"
        ]
        for key in forbidden {
            let message: [String: Any] = ["url": url, key: "nope"]
            XCTAssertThrowsError(
                try ExternalDownload.stage(nativeMessage: message, downloadRoot: root)
            ) { error in
                XCTAssertEqual(error as? EngineError, EngineError.handoffRejected(key), key)
            }
        }
        let wrongTypes: [Any] = [
            ["url": 12] as [String: Any],
            ["url": url, "filename": ["a.bin"]] as [String: Any],
            "https://example.com/a.bin",
            ["filename": "a.bin"] as [String: Any]
        ]
        for message in wrongTypes {
            XCTAssertThrowsError(
                try ExternalDownload.stage(nativeMessage: message, downloadRoot: root)
            )
        }
        let spaced = try ExternalDownload.stage(
            nativeMessage: ["url": url, "filename": "   "],
            downloadRoot: root
        )
        XCTAssertNil(spaced.outputName)
        let named = try ExternalDownload.stage(
            nativeMessage: ["url": url, "filename": "my file.zip"],
            downloadRoot: root
        )
        XCTAssertEqual(named.outputName, "my file.zip")
        XCTAssertEqual(named.options.keys.sorted(), ["out"])
    }

    func testOpenURLRejectsMalformedRequests() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let samples = [
            "https://example.com/a.bin",
            "umbilical://example.com/?url=https://example.com/a.bin",
            "umbilical://user:pass@download?url=https://example.com/a.bin",
            "umbilical://download/extra?url=https://example.com/a.bin",
            "umbilical://download?url=https://example.com/a.bin#frag",
            "umbilical://download",
            "umbilical://download?filename=a.bin",
            "umbilical://download?url=https://example.com/a.bin&url=https://example.com/b.bin",
            "umbilical://download?url=https://example.com/a.bin&cookie=secret",
            "umbilical://download?url=https://example.com/a.bin&header=Bearer",
            "umbilical://download?url=file:///tmp/x",
            "umbilical://download?url=javascript:alert(1)",
            "umbilical://download?url=https://user:pw@example.com/a",
            "umbilical://download?url=https://example.com/a.bin&filename=../x"
        ]
        for sample in samples {
            let url = try XCTUnwrap(URL(string: sample), sample)
            XCTAssertThrowsError(
                try ExternalDownload.stage(openURL: url, downloadRoot: root),
                sample
            )
        }
        let cookie = try XCTUnwrap(
            URL(string: "umbilical://download?url=https://example.com/a.bin&cookie=secret")
        )
        XCTAssertThrowsError(
            try ExternalDownload.stage(openURL: cookie, downloadRoot: root)
        ) { error in
            XCTAssertEqual(error as? EngineError, EngineError.handoffRejected("cookie"))
        }
        let file = try XCTUnwrap(URL(string: "umbilical://download?url=file:///tmp/x"))
        XCTAssertThrowsError(
            try ExternalDownload.stage(openURL: file, downloadRoot: root)
        ) { error in
            XCTAssertEqual(error as? EngineError, EngineError.schemeRejected("file"))
        }
    }

    private func queryNames(_ url: URL) throws -> [String] {
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        return try XCTUnwrap(components.queryItems).map(\.name)
    }

    private func makeRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "umb-handoff-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
