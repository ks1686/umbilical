// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalEngine

final class ExternalDownloadTests: XCTestCase {
    func testHTTPAndHTTPSRoundTripThroughTheOpenURL() throws {
        let root = try makeTemporaryDirectory()
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
        let root = try makeTemporaryDirectory()
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

    func testMagnetBTMHAndPrefixRules() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let digest = String(repeating: "ab", count: 32)
        let btmh = "magnet:?xt=urn:btmh:1220\(digest)"
        let staged = try ExternalDownload.stage(urlText: btmh, filename: nil, downloadRoot: root)
        XCTAssertTrue(staged.uri.hasPrefix("magnet:?"))
        XCTAssertTrue(staged.uri.contains("btmh"))
        XCTAssertEqual(staged.kind, .download)
        XCTAssertThrowsError(
            try ExternalDownload.stage(
                urlText: "magnet:xt=urn:btih:" + String(repeating: "ab", count: 20),
                filename: nil,
                downloadRoot: root
            )
        )
        let magnetOpen = try XCTUnwrap(URL(string: btmh))
        let fromFinder = try ExternalDownload.stage(openURL: magnetOpen, downloadRoot: root)
        XCTAssertEqual(fromFinder.uri, staged.uri)
    }

    func testExtraFieldsAndNonStringsAreRejected() throws {
        let root = try makeTemporaryDirectory()
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

    func testVideoFlagUsesTheVideoHostAndRejectsMagnets() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let staged = try ExternalDownload.stage(
            nativeMessage: [
                "url": "https://example.com/watch",
                "filename": "clip.mp4",
                "video": true
            ] as [String: Any],
            downloadRoot: root
        )
        XCTAssertEqual(staged.kind, .video)
        let open = try ExternalDownload.openURL(for: staged, downloadRoot: root)
        XCTAssertEqual(open.host, ExternalDownload.videoHost)
        let names = try queryNames(open)
        XCTAssertEqual(names, ["url", "filename"])
        let again = try ExternalDownload.stage(openURL: open, downloadRoot: root)
        XCTAssertEqual(again.kind, .video)
        XCTAssertEqual(again.outputName, "clip.mp4")
        XCTAssertThrowsError(
            try ExternalDownload.stage(
                urlText: "magnet:?xt=urn:btih:" + String(repeating: "ab", count: 20),
                filename: nil,
                downloadRoot: root,
                kind: .video
            )
        )
        XCTAssertThrowsError(
            try ExternalDownload.stage(
                nativeMessage: [
                    "url": "https://example.com/watch",
                    "video": false
                ] as [String: Any],
                downloadRoot: root
            )
        )
        XCTAssertThrowsError(
            try ExternalDownload.stage(
                nativeMessage: [
                    "url": "https://example.com/watch",
                    "video": "true"
                ] as [String: Any],
                downloadRoot: root
            )
        )
    }

    func testLocalTorrentAndMetalinkFilesStageThroughTheGate() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let torrent = TorrentBuild.single(
            name: "payload.bin",
            payload: Data([1, 2, 3, 4]),
            pieceLength: 16,
            announce: "http://127.0.0.1:9/announce"
        )
        let torrentFile = root.appendingPathComponent("payload.torrent")
        try torrent.bytes.write(to: torrentFile)
        let staged = try ExternalDownload.stage(localFile: torrentFile, downloadRoot: root)
        XCTAssertEqual(staged.kind, .torrentFile)
        XCTAssertEqual(staged.outputName, "payload.torrent")
        let confirmed = try ExternalDownload.confirm(staged, downloadRoot: root)
        XCTAssertEqual(confirmed.kind, .torrentFile)
        XCTAssertThrowsError(try ExternalDownload.openURL(for: staged, downloadRoot: root))

        let metalink = root.appendingPathComponent("list.meta4")
        try Data("<metalink></metalink>".utf8).write(to: metalink)
        let meta = try ExternalDownload.stage(localFile: metalink, downloadRoot: root)
        XCTAssertEqual(meta.kind, .metalinkFile)

        let random = root.appendingPathComponent("notes.txt")
        try Data("hi".utf8).write(to: random)
        XCTAssertThrowsError(try ExternalDownload.stage(localFile: random, downloadRoot: root))
    }
}
