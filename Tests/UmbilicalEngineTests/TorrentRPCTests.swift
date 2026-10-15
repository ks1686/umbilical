// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalEngine

final class TorrentRPCTests: XCTestCase {
    func testAddSendsCanonicalMagnet() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (client, transport) = recordingClient(root: root)
        let base32 = String(repeating: "a", count: 32)
        _ = try await client.add(url: try testURL("magnet:?xt=urn:btih:\(base32)"))
        let params = try XCTUnwrap(transport.parameters.first)
        let uris = try XCTUnwrap(params[1] as? [String])
        let zeros = String(repeating: "0", count: 40)
        XCTAssertEqual(uris, ["magnet:?xt=urn:btih:\(zeros)"])
    }

    func testFileAndJavascriptStayRejected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (client, transport) = recordingClient(root: root)
        for raw in ["file:///tmp/x", "javascript:alert(1)"] {
            do {
                _ = try await client.add(url: try testURL(raw))
                XCTFail("accepted \(raw)")
            } catch let error as EngineError {
                guard case .schemeRejected = error else {
                    return XCTFail("unexpected \(error)")
                }
            }
        }
        XCTAssertTrue(transport.methods.isEmpty)
    }

    func testAddTorrentSendsBase64AndNoWebSeeds() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let torrent = TorrentBuild.single(
            name: "job.bin",
            payload: Data([9]),
            pieceLength: 16,
            announce: "http://127.0.0.1/announce"
        )
        let file = root.appendingPathComponent("job.torrent")
        try torrent.bytes.write(to: file)
        let (client, transport) = recordingClient(root: root)
        _ = try await client.addTorrent(file: file, options: ["select-file": "1"])
        let params = try XCTUnwrap(transport.parameters.first)
        XCTAssertEqual(params[1] as? String, torrent.bytes.base64EncodedString())
        let uris = try XCTUnwrap(params[2] as? [String])
        XCTAssertEqual(uris, [])
    }

    func testSelectFileRangeIsRejectedBeforeRPC() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try writeSample(root)
        let (client, transport) = recordingClient(root: root)
        do {
            _ = try await client.addTorrent(file: file, options: ["select-file": "2"])
            XCTFail("out of range select-file was accepted")
        } catch let error as EngineError {
            guard case .optionValueRejected("select-file") = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(transport.methods.isEmpty)
    }

    func testHookIsRejectedBeforeTheTorrentIsRead() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let missing = root.appendingPathComponent("missing.torrent")
        let (client, transport) = recordingClient(root: root)
        do {
            _ = try await client.addTorrent(
                file: missing,
                options: ["on-download-complete": "id"]
            )
            XCTFail("hook was accepted")
        } catch let error as EngineError {
            guard case .hookRejected = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(transport.methods.isEmpty)
    }

    func testSymlinkNamedLikeTheTorrentIsRejected() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"),
            withDestinationURL: outside
        )
        let torrent = TorrentBuild.single(
            name: "escape",
            payload: Data([1]),
            pieceLength: 16,
            announce: "http://127.0.0.1/announce"
        )
        let file = root.appendingPathComponent("job.torrent")
        try torrent.bytes.write(to: file)
        let (client, transport) = recordingClient(root: root)
        do {
            _ = try await client.addTorrent(file: file)
            XCTFail("symlink name was accepted")
        } catch let error as EngineError {
            guard case .directoryRejected = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(transport.methods.isEmpty)
    }
}

private func recordingClient(root: URL) -> (RPCClient, RecordingTransport) {
    let transport = RecordingTransport()
    let client = RPCClient(
        port: 1,
        secret: "secret",
        downloadDirectory: root,
        transport: transport,
        quarantine: RecordingQuarantine()
    )
    return (client, transport)
}

private func writeSample(_ root: URL) throws -> URL {
    let torrent = TorrentBuild.single(
        name: "job.bin",
        payload: Data([9]),
        pieceLength: 16,
        announce: "http://127.0.0.1/announce"
    )
    let file = root.appendingPathComponent("job.torrent")
    try torrent.bytes.write(to: file)
    return file
}
