// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalEngine

final class TorrentMetadataTests: XCTestCase {
    func testSHA1MatchesKnownVectors() {
        let abc = TorrentBuild.hex(SHA1Digest.hash(Data("abc".utf8)))
        XCTAssertEqual(abc, "a9993e364706816aba3e25717850c26c9cd0d89d")
        let empty = TorrentBuild.hex(SHA1Digest.hash(Data()))
        XCTAssertEqual(empty, "da39a3ee5e6b4b0d3255bfef95601890afd80709")
    }

    func testParserAcceptsAPrivateTorrent() throws {
        let torrent = sampleTorrent(name: "ok.bin", announce: "http://127.0.0.1/announce")
        let parsed = try TorrentMetadata.parse(torrent.bytes)
        XCTAssertEqual(parsed.name, "ok.bin")
        XCTAssertEqual(parsed.fileCount, 1)
        XCTAssertEqual(parsed.totalLength, 4)
    }

    func testParserRejectsEscapesAndForeignURLs() {
        XCTAssertThrowsError(try TorrentMetadata.parse(sampleTorrent(name: "../x").bytes))
        let nested = TorrentBuild.multiple(
            directory: "bundle",
            files: [TorrentBuild.FileSpec(components: [".."], bytes: Data([1]))],
            pieceLength: 16,
            announce: "http://127.0.0.1/announce"
        )
        XCTAssertThrowsError(try TorrentMetadata.parse(nested.bytes))
        let web = sampleTorrent(name: "ok.bin", urlList: ["file:///tmp/x"])
        XCTAssertThrowsError(try TorrentMetadata.parse(web.bytes))
        let tracker = sampleTorrent(name: "ok.bin", announce: "file:///tmp/x")
        XCTAssertThrowsError(try TorrentMetadata.parse(tracker.bytes))
    }
}

final class MagnetLinkTests: XCTestCase {
    func testCanonicalHexAndBase32() throws {
        let hex = String(repeating: "0", count: 40)
        let upper = try testURL("magnet:?xt=urn:btih:\(hex.uppercased())")
        XCTAssertEqual(try MagnetLink.canonical(upper), "magnet:?xt=urn:btih:\(hex)")
        let base32 = String(repeating: "A", count: 32)
        let encoded = try testURL("magnet:?xt=urn:btih:\(base32)")
        XCTAssertEqual(try MagnetLink.canonical(encoded), "magnet:?xt=urn:btih:\(hex)")
    }

    func testBadDisplayNameAndWebSeed() throws {
        let hash = String(repeating: "ab", count: 20)
        let name = try testURL("magnet:?xt=urn:btih:\(hash)&dn=../x")
        XCTAssertThrowsError(try MagnetLink.canonical(name)) { error in
            guard case EngineError.magnetRejected("dn") = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        let web = try testURL("magnet:?xt=urn:btih:\(hash)&ws=file:///tmp/x")
        XCTAssertThrowsError(try MagnetLink.canonical(web))
    }

    func testBTMHOnlyAndMagnetPrefix() throws {
        let digest = String(repeating: "cd", count: 32)
        let raw = try testURL("magnet:?xt=urn:btmh:1220\(digest)")
        let canonical = try MagnetLink.canonical(raw)
        XCTAssertTrue(canonical.hasPrefix("magnet:?"))
        XCTAssertTrue(canonical.contains("btmh"))
        XCTAssertFalse(canonical.contains("btih"))
        let missingQuery = try testURL("magnet:xt=urn:btih:" + String(repeating: "ab", count: 20))
        XCTAssertThrowsError(try MagnetLink.canonical(missingQuery))
        let withHost = try testURL(
            "magnet://host?xt=urn:btih:" + String(repeating: "ab", count: 20)
        )
        XCTAssertThrowsError(try MagnetLink.canonical(withHost))
    }
}

private func sampleTorrent(
    name: String,
    announce: String? = "http://127.0.0.1/announce",
    urlList: [String] = []
) -> BuiltTorrent {
    TorrentBuild.single(
        name: name,
        payload: Data([1, 2, 3, 4]),
        pieceLength: 16,
        announce: announce,
        urlList: urlList
    )
}
