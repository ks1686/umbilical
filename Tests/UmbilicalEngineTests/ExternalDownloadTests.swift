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
            "blob:https://example.com/a": EngineError.schemeRejected("blob"),
            "-o": EngineError.schemeRejected("option"),
            "--header=Bearer": EngineError.schemeRejected("option"),
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
        let dashOpen = try XCTUnwrap(
            URL(string: "umbilical://download?url=-o")
        )
        XCTAssertThrowsError(
            try ExternalDownload.stage(openURL: dashOpen, downloadRoot: root)
        ) { error in
            XCTAssertEqual(error as? EngineError, EngineError.schemeRejected("option"))
        }
        let dataOpen = try XCTUnwrap(
            URL(string: "umbilical://download?url=data:text/plain,hi")
        )
        XCTAssertThrowsError(try ExternalDownload.stage(openURL: dataOpen, downloadRoot: root))
        let jsOpen = try XCTUnwrap(
            URL(string: "umbilical://download?url=javascript:alert(1)")
        )
        XCTAssertThrowsError(try ExternalDownload.stage(openURL: jsOpen, downloadRoot: root))
    }

    func testRejectedSchemesAreRejectedOnEveryEntryPoint() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rejected = [
            "file:///tmp/x",
            "javascript:alert(1)",
            "data:text/plain,hi",
            "-o",
            "--header=Bearer",
            "-https://example.com/a.bin"
        ]
        for text in rejected {
            XCTAssertThrowsError(
                try ExternalDownload.stage(urlText: text, filename: nil, downloadRoot: root),
                text
            )
            XCTAssertThrowsError(
                try ExternalDownload.stage(
                    nativeMessage: ["url": text],
                    downloadRoot: root
                ),
                text
            )
            if let direct = URL(string: text), direct.scheme != nil, !text.hasPrefix("-") {
                XCTAssertThrowsError(
                    try ExternalDownload.stage(openURL: direct, downloadRoot: root),
                    text
                )
            }
        }
        let tooLong = "https://example.com/" + String(repeating: "a", count: 4096)
        XCTAssertThrowsError(
            try ExternalDownload.stage(urlText: tooLong, filename: nil, downloadRoot: root)
        ) { error in
            XCTAssertEqual(error as? EngineError, EngineError.handoffRejected("length"))
        }
        XCTAssertThrowsError(
            try ExternalDownload.stage(
                nativeMessage: ["url": "https://example.com/a.bin", "filename": "-o"],
                downloadRoot: root
            )
        )
    }

    func testAcceptedSchemesRoundTripNativeMessageAndOpenURL() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let hash = String(repeating: "ab", count: 20)
        let digest = String(repeating: "cd", count: 32)
        let accepted = [
            ("http://example.com/a.bin", "a.bin", "http"),
            ("https://example.com/a.bin", "a.bin", "https"),
            ("ftp://example.com/a.bin", "a.bin", "ftp"),
            ("sftp://files.example.com/a.bin", "a.bin", "sftp"),
            ("https://example.com/pack.metalink", "pack.metalink", "https"),
            ("http://mirror.example.com/list.meta4", "list.meta4", "http"),
            ("ftp://example.com/pack.metalink", "pack.metalink", "ftp"),
            ("sftp://files.example.com/list.meta4", "list.meta4", "sftp"),
            ("magnet:?xt=urn:btih:\(hash)", nil, "magnet"),
            ("magnet:?xt=urn:btmh:1220\(digest)", nil, "magnet")
        ]
        for (urlText, filename, scheme) in accepted {
            let fromText = try ExternalDownload.stage(
                urlText: urlText,
                filename: filename,
                downloadRoot: root
            )
            XCTAssertEqual(fromText.url.scheme?.lowercased(), scheme, urlText)
            XCTAssertEqual(fromText.kind, .download, urlText)
            XCTAssertEqual(fromText.outputName, filename, urlText)
            XCTAssertLessThanOrEqual(fromText.uri.count, 4096, urlText)

            var message: [String: Any] = ["url": urlText]
            if let filename {
                message["filename"] = filename
            }
            let fromNative = try ExternalDownload.stage(
                nativeMessage: message,
                downloadRoot: root
            )
            XCTAssertEqual(fromNative.uri, fromText.uri, urlText)
            XCTAssertEqual(fromNative.outputName, filename, urlText)

            let open = try ExternalDownload.openURL(for: fromText, downloadRoot: root)
            XCTAssertEqual(open.scheme, ExternalDownload.scheme, urlText)
            XCTAssertEqual(open.host, ExternalDownload.host, urlText)
            let fromOpen = try ExternalDownload.stage(openURL: open, downloadRoot: root)
            XCTAssertEqual(fromOpen.uri, fromText.uri, urlText)
            XCTAssertEqual(fromOpen.outputName, filename, urlText)
            let confirmed = try ExternalDownload.confirm(fromOpen, downloadRoot: root)
            XCTAssertEqual(confirmed.kind, .download, urlText)
            XCTAssertEqual(confirmed.uri, fromText.uri, urlText)
        }
    }

    func testHTTPMetalinkAndFTPOpenDirectly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let metalink = try XCTUnwrap(URL(string: "https://example.com/pack.metalink"))
        let staged = try ExternalDownload.stage(openURL: metalink, downloadRoot: root)
        XCTAssertEqual(staged.url.scheme?.lowercased(), "https")
        XCTAssertEqual(staged.outputName, "pack.metalink")
        XCTAssertEqual(staged.kind, .download)
        let meta4 = try XCTUnwrap(URL(string: "http://mirror.example.com/list.meta4"))
        let stagedMeta4 = try ExternalDownload.stage(openURL: meta4, downloadRoot: root)
        XCTAssertEqual(stagedMeta4.outputName, "list.meta4")
        let ftp = try XCTUnwrap(URL(string: "ftp://example.com/a.bin"))
        let stagedFTP = try ExternalDownload.stage(openURL: ftp, downloadRoot: root)
        XCTAssertEqual(stagedFTP.url.scheme?.lowercased(), "ftp")
        let sftp = try XCTUnwrap(URL(string: "sftp://files.example.com/a.bin"))
        let stagedSFTP = try ExternalDownload.stage(openURL: sftp, downloadRoot: root)
        XCTAssertEqual(stagedSFTP.url.scheme?.lowercased(), "sftp")
    }

    func testVideoFlagUsesTheVideoHostAndRejectsMagnets() throws {
        let root = try makeRoot()
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
                nativeMessage: ["url": "https://example.com/watch", "video": false] as [String: Any],
                downloadRoot: root
            )
        )
        XCTAssertThrowsError(
            try ExternalDownload.stage(
                nativeMessage: ["url": "https://example.com/watch", "video": "true"] as [String: Any],
                downloadRoot: root
            )
        )
    }

    func testDashPrefixedNamesAndVideoQueryAreRejected() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(
            try ExternalDownload.stage(
                urlText: "https://example.com/a.bin",
                filename: "-o",
                downloadRoot: root
            )
        )
        let videoQuery = try XCTUnwrap(
            URL(string: "umbilical://download?url=https://example.com/a.bin&video=true")
        )
        XCTAssertThrowsError(try ExternalDownload.stage(openURL: videoQuery, downloadRoot: root)) {
            error in
            XCTAssertEqual(error as? EngineError, EngineError.handoffRejected("video"))
        }
    }

    func testMagnetBTMHAndPrefixRules() throws {
        let root = try makeRoot()
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

    func testLocalTorrentAndMetalinkFilesStageThroughTheGate() throws {
        let root = try makeRoot()
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
