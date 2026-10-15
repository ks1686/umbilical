// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalEngine

final class FollowFileTests: XCTestCase {
    func testHTTPTorrentAndMetalinkStayPlainFiles() async throws {
        let aria2 = try TestBins.requireAria2()
        let servers = try startFollowServers()
        defer { servers.stop() }
        let engine = try await startDownloadEngine(aria2: aria2)
        defer { engine.stop() }
        let global = try await globalOptions(engine.client)
        XCTAssertEqual(global["follow-torrent"], "false")
        XCTAssertEqual(global["follow-metalink"], "false")
        let torrentGID = try await assertSavedAsFile(engine, servers.torrent)
        let metalinkGID = try await assertSavedAsFile(engine, servers.metalink)
        let known = try await knownGIDs(engine.client)
        XCTAssertEqual(known, [torrentGID, metalinkGID])
    }
}

private struct PlainExpect {
    var url: URL
    var bytes: Data
    var name: String
    var absent: String
}

private struct FollowServers {
    var torrentServer: LocalHTTPServer
    var metalinkServer: LocalHTTPServer
    var torrent: PlainExpect
    var metalink: PlainExpect

    func stop() {
        torrentServer.stop()
        metalinkServer.stop()
    }
}

private func startFollowServers() throws -> FollowServers {
    let payload = Data("payl".utf8)
    let torrent = TorrentBuild.single(
        name: "payload.bin",
        payload: payload,
        pieceLength: 16_384,
        announce: nil
    )
    let metalink = metalinkDocument()
    let torrentServer = try LocalHTTPServer(body: torrent.bytes, hold: false)
    let metalinkServer = try LocalHTTPServer(body: metalink, hold: false)
    torrentServer.start()
    metalinkServer.start()
    return FollowServers(
        torrentServer: torrentServer,
        metalinkServer: metalinkServer,
        torrent: PlainExpect(
            url: try testURL("http://127.0.0.1:\(torrentServer.port)/job.torrent"),
            bytes: torrent.bytes,
            name: "job.torrent",
            absent: "payload.bin"
        ),
        metalink: PlainExpect(
            url: try testURL("http://127.0.0.1:\(metalinkServer.port)/job.metalink"),
            bytes: metalink,
            name: "job.metalink",
            absent: "from-metalink.bin"
        )
    )
}

private func metalinkDocument() -> Data {
    let lines = [
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
        "<metalink xmlns=\"urn:ietf:params:xml:ns:metalink\">",
        "  <file name=\"from-metalink.bin\">",
        "    <size>4</size>",
        "    <url>http://127.0.0.1:9/from-metalink.bin</url>",
        "  </file>",
        "</metalink>",
        ""
    ]
    return Data(lines.joined(separator: "\n").utf8)
}

private func assertSavedAsFile(
    _ engine: DownloadEngine,
    _ expect: PlainExpect
) async throws -> String {
    let gid = try await engine.client.add(url: expect.url, options: ["split": "1"])
    let object = try await waitUntilComplete(engine.client, gid)
    let followed = followedGIDs(object)
    XCTAssertTrue(followed.isEmpty, "followedBy \(followed) for \(expect.name)")
    let path = try XCTUnwrap(firstPath(object))
    XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, expect.name)
    let saved = try Data(contentsOf: URL(fileURLWithPath: path))
    XCTAssertEqual(saved, expect.bytes)
    let child = engine.downloads.appendingPathComponent(expect.absent)
    XCTAssertFalse(FileManager.default.fileExists(atPath: child.path))
    return gid
}

private func waitUntilComplete(_ client: RPCClient, _ gid: String) async throws -> [String: Any] {
    let deadline = Date().addingTimeInterval(20)
    while Date() < deadline {
        let object = try await tellStatus(client, gid)
        let status = object["status"] as? String ?? ""
        if status == "complete" {
            return object
        }
        if status == "error" {
            throw EngineError.unexpectedStatus(object["errorMessage"] as? String ?? status)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw FixtureError.timedOut
}

private func tellStatus(_ client: RPCClient, _ gid: String) async throws -> [String: Any] {
    let transport = LoopbackTransport(port: client.port, timeoutSeconds: 5)
    let keys = ["gid", "status", "errorMessage", "followedBy", "files"]
    let result = try await transport.call(
        method: "aria2.tellStatus",
        parameters: ["token:\(client.secret)", gid, keys]
    )
    guard let object = result as? [String: Any] else {
        throw FixtureError.badFixture
    }
    return object
}

private func followedGIDs(_ object: [String: Any]) -> [String] {
    let list = object["followedBy"] as? [Any] ?? []
    return list.compactMap { $0 as? String }.filter { !$0.isEmpty }
}

private func firstPath(_ object: [String: Any]) -> String? {
    let files = object["files"] as? [[String: Any]] ?? []
    return files.first?["path"] as? String
}

private func knownGIDs(_ client: RPCClient) async throws -> Set<String> {
    let transport = LoopbackTransport(port: client.port, timeoutSeconds: 5)
    let token = "token:\(client.secret)"
    var found = Set<String>()
    found.formUnion(try await gidList(transport, token, "aria2.tellActive", []))
    found.formUnion(try await gidList(transport, token, "aria2.tellWaiting", [0, 100]))
    found.formUnion(try await gidList(transport, token, "aria2.tellStopped", [0, 100]))
    return found
}

private func gidList(
    _ transport: LoopbackTransport,
    _ token: String,
    _ method: String,
    _ extra: [Any]
) async throws -> Set<String> {
    var params: [Any] = [token]
    params.append(contentsOf: extra)
    let result = try await transport.call(method: method, parameters: params)
    let rows = result as? [[String: Any]] ?? []
    return Set(rows.compactMap { $0["gid"] as? String })
}
