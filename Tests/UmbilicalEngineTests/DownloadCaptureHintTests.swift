// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalEngine

final class DownloadCaptureHintTests: XCTestCase {
    func testTorrentAndMetalinkExtensions() throws {
        let torrent = try testURL("https://example.com/files/movie.torrent")
        XCTAssertTrue(DownloadCaptureHint.isTorrent(url: torrent, filename: nil))
        let named = try testURL("https://example.com/dl")
        XCTAssertTrue(DownloadCaptureHint.isTorrent(url: named, filename: "a.torrent"))
        XCTAssertFalse(
            DownloadCaptureHint.isTorrent(url: try testURL("https://example.com/a.zip"), filename: nil)
        )
        XCTAssertTrue(
            DownloadCaptureHint.isMetalink(url: try testURL("https://example.com/a.meta4"), filename: nil)
        )
        XCTAssertTrue(
            DownloadCaptureHint.isMetalink(url: try testURL("https://example.com/a"), filename: "pack.metalink")
        )
        XCTAssertTrue(
            DownloadCaptureHint.looksLikeDownload(url: try testURL("https://example.com/a.zip"), filename: nil)
        )
        XCTAssertFalse(
            DownloadCaptureHint.looksLikeDownload(
                url: try testURL("https://example.com/index.html"),
                filename: nil
            )
        )
        XCTAssertTrue(DownloadCaptureHint.fileExtensions.contains("torrent"))
        XCTAssertTrue(DownloadCaptureHint.fileExtensions.contains("metalink"))
        XCTAssertTrue(DownloadCaptureHint.fileExtensions.contains("meta4"))
    }
}

final class CookieFreeHTTPTests: XCTestCase {
    func testFetchDoesNotExceedTheSizeCapAndParsesATorrent() async throws {
        let torrent = TorrentBuild.single(
            name: "payload.bin",
            payload: Data([1, 2, 3, 4]),
            pieceLength: 16,
            announce: "http://127.0.0.1:9/announce"
        )
        let server = try LocalHTTPServer(body: torrent.bytes, hold: false)
        server.start()
        defer { server.stop() }
        let url = try testURL("http://127.0.0.1:\(server.port)/payload.torrent")
        let data = try await CookieFreeHTTP.get(url)
        XCTAssertEqual(data, torrent.bytes)
        _ = try TorrentMetadata.parse(data)

        do {
            _ = try await CookieFreeHTTP.get(url, maxBytes: 4)
            XCTFail("expected the size cap to reject the body")
        } catch let error as EngineError {
            guard case .torrentRejected("size") = error else {
                XCTFail("unexpected \(error)")
                return
            }
        }
    }
}

final class HandoffImportTests: XCTestCase {
    func testCopyAndFetchLandInsideTheDownloadFolder() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "umb-import-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        // realpath. On macOS /var is a symlink to /private/var.
        let root = URL(
            fileURLWithPath: try DownloadPath.resolveInside(root: scratch, raw: scratch.path),
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let torrent = TorrentBuild.single(
            name: "payload.bin",
            payload: Data([9, 8, 7, 6]),
            pieceLength: 16,
            announce: "http://127.0.0.1:9/announce"
        )
        let source = root.appendingPathComponent("outside.torrent")
        try torrent.bytes.write(to: source)
        let copied = try HandoffImport.copyLocal(
            url: source,
            filename: "payload.torrent",
            directory: root,
            torrent: true
        )
        XCTAssertEqual(copied.lastPathComponent, "payload.torrent")
        XCTAssertEqual(try DownloadPath.resolveInside(root: root, raw: copied.path), copied.path)

        let server = try LocalHTTPServer(body: torrent.bytes, hold: false)
        server.start()
        defer { server.stop() }
        let url = try testURL("http://127.0.0.1:\(server.port)/payload.torrent")
        let fetched = try await HandoffImport.fetchTorrent(
            url: url,
            filename: "from-http.torrent",
            directory: root
        )
        XCTAssertEqual(fetched.lastPathComponent, "from-http.torrent")
        XCTAssertEqual(try Data(contentsOf: fetched), torrent.bytes)
    }
}
