// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import UmbilicalEngine

final class RPCIntegrationTests: XCTestCase {
    func testRealAria2RejectsBadSecretsAndBrowserWebSocket() async throws {
        let aria2 = try TestBins.requireAria2()
        let downloads = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let supervisor = EngineSupervisor(
            aria2Executable: aria2,
            downloadDirectory: downloads,
            watchHelper: try TestBins.watchHelper(),
            quarantine: RecordingQuarantine()
        )
        defer { supervisor.stop() }
        let prepared = try supervisor.prepareLaunch()
        XCTAssertEqual(try POSIX.permissions(of: prepared.settingsFile.path), 0o600)
        let settings = try String(contentsOf: prepared.settingsFile, encoding: .utf8)
        XCTAssertTrue(settings.contains("rpc-listen-all=false"))
        XCTAssertTrue(settings.contains("rpc-allow-origin-all=false"))
        XCTAssertTrue(settings.contains("check-certificate=true"))
        XCTAssertTrue(settings.contains("seed-time=0"))
        XCTAssertTrue(settings.contains("max-upload-limit=1K"))
        let client = try await supervisor.completeLaunch(prepared, probe: LiveRPCProbe())
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.settingsFile.path))
        guard let root = supervisor.processIdentifier else {
            XCTFail("aria2 supervisor is not running")
            return
        }
        let blobs = ProcessTree.snapshot(root: root)
        for blob in blobs {
            XCTAssertFalse(blob.contains(prepared.secret), "secret leaked into a process")
            XCTAssertFalse(blob.contains("--rpc-secret"))
        }
        let version = try await client.version()
        XCTAssertFalse(version.isEmpty)

        let missing = try json(method: "aria2.getVersion", params: [], port: client.port)
        let missingError = try rpcError(missing)
        XCTAssertEqual(missingError.code, 1)
        XCTAssertEqual(missingError.message, "Unauthorized")

        let wrong = try json(method: "aria2.getVersion", params: ["token:wrong-secret"], port: client.port)
        let wrongError = try rpcError(wrong)
        XCTAssertEqual(wrongError.code, 1)

        let browser = try json(
            method: "aria2.getVersion",
            params: ["token:\(prepared.secret)"],
            port: client.port,
            origin: "https://evil.example"
        )
        XCTAssertNil(browser.headers["access-control-allow-origin"])
        XCTAssertEqual(browser.status, 200)

        let handshake = websocketRequest(port: client.port)
        let raw = try LoopbackHTTP.exchange(port: client.port, request: handshake)
        let text = String(decoding: raw, as: UTF8.self)
        XCTAssertFalse(text.contains("101 Switching Protocols"))
        XCTAssertFalse(text.lowercased().contains("access-control-allow-origin"))
        XCTAssertTrue(text.contains("400"))

        let listeners = try listeningAddresses(root: root, port: client.port)
        XCTAssertFalse(listeners.isEmpty)
        for address in listeners {
            XCTAssertTrue(address == "127.0.0.1" || address == "::1", "listener \(address)")
        }
    }

    func testHTTPDownloadPauseResumeRemoveAndQuarantine() async throws {
        let aria2 = try TestBins.requireAria2()
        let downloads = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: downloads) }
        let payload = Data(repeating: 0x61, count: 128 * 1024)
        let server = try LocalHTTPServer(body: payload, hold: true)
        defer { server.stop() }
        let quarantine = RecordingQuarantine()
        let supervisor = EngineSupervisor(
            aria2Executable: aria2,
            downloadDirectory: downloads,
            watchHelper: try TestBins.watchHelper(),
            quarantine: quarantine
        )
        defer { supervisor.stop() }
        let client = try await supervisor.start()
        do {
            try await exerciseDownload(client, server: server, payload: payload, downloads: downloads, quarantine: quarantine)
        } catch {
            XCTFail("download control failed: \(error) aria2=\(supervisor.launchOutput(redacting: client.secret))")
        }
    }

    private func exerciseDownload(
        _ client: RPCClient,
        server: LocalHTTPServer,
        payload: Data,
        downloads: URL,
        quarantine: RecordingQuarantine
    ) async throws {
        let gid = try await client.add(
            url: URL(string: "http://127.0.0.1:\(server.port)/payload.bin")!,
            options: ["out": "payload.bin", "split": "1"]
        )
        let active = try await waitStatus(client, gid: gid, timeout: 15) { status in
            status.state == .active && status.completedLength > 0
        }
        XCTAssertEqual(active.state, .active)
        try await client.pause(gid: gid)
        let paused = try await waitStatus(client, gid: gid, timeout: 10) { $0.state == .paused }
        XCTAssertEqual(paused.state, .paused)
        try await client.resume(gid: gid)
        server.release()
        let done = try await waitStatus(client, gid: gid, timeout: 20) { $0.state == .complete }
        XCTAssertEqual(done.state, .complete)
        XCTAssertFalse(quarantine.paths.isEmpty)
        let file = downloads.appendingPathComponent("payload.bin")
        let saved = try Data(contentsOf: file)
        XCTAssertEqual(saved, payload)
        XCTAssertTrue(quarantine.paths.contains(file.path))

        let removalServer = try LocalHTTPServer(body: payload, hold: true)
        defer { removalServer.stop() }
        let removal = try await client.add(
            url: URL(string: "http://127.0.0.1:\(removalServer.port)/other.bin")!,
            options: ["out": "other.bin", "split": "1"]
        )
        _ = try await waitStatus(client, gid: removal, timeout: 15) { status in
            status.state == .active || status.state == .waiting
        }
        try await client.remove(gid: removal)
        let removed = try await waitStatus(client, gid: removal, timeout: 10) { $0.state == .removed }
        XCTAssertEqual(removed.state, .removed)
    }

    func testSystemQuarantineAttribute() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("done.bin")
        try Data("payload".utf8).write(to: file)
        do {
            try SystemQuarantine().markDownloaded(file: file)
        } catch {
            #if os(macOS)
            throw error
            #else
            throw XCTSkip("com.apple.quarantine is not stored on this filesystem")
            #endif
        }
        let value = try QuarantineMark.read(path: file.path)
        XCTAssertTrue(value.hasPrefix("0083;"))
        XCTAssertTrue(value.contains(";umbilical;"))
    }
}

private func json(
    method: String,
    params: [Any],
    port: UInt16,
    origin: String? = nil
) throws -> HTTPMessage {
    var headers: [String: String] = [:]
    if let origin {
        headers["Origin"] = origin
    }
    let body = try JSONSerialization.data(withJSONObject: [
        "jsonrpc": "2.0",
        "id": "1",
        "method": method,
        "params": params,
    ])
    return try LoopbackHTTP.post(port: port, body: body, headers: headers)
}

private func rpcError(_ message: HTTPMessage) throws -> (code: Int, message: String) {
    let object = try JSONSerialization.jsonObject(with: message.body) as? [String: Any]
    let error = object?["error"] as? [String: Any]
    let code = (error?["code"] as? Int) ?? (error?["code"] as? NSNumber)?.intValue
    let text = error?["message"] as? String
    guard let code, let text else {
        throw EngineError.transport("missing rpc error")
    }
    return (code, text)
}

private func websocketRequest(port: UInt16) -> Data {
    let lines = [
        "GET /jsonrpc HTTP/1.1",
        "Host: 127.0.0.1:\(port)",
        "Upgrade: websocket",
        "Connection: Upgrade",
        "Origin: https://evil.example",
        // RFC 6455 sample nonce ("the sample nonce"), not a credential.
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==",
        "Sec-WebSocket-Version: 13",
        "",
        "",
    ]
    return Data(lines.joined(separator: "\r\n").utf8)
}

private func waitStatus(
    _ client: RPCClient,
    gid: String,
    timeout: TimeInterval,
    where predicate: (DownloadStatus) -> Bool
) async throws -> DownloadStatus {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let status = try await client.status(gid: gid)
        if status.state == .error {
            throw EngineError.unexpectedStatus(status.errorMessage ?? "error")
        }
        if predicate(status) {
            return status
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw EngineError.listenTimeout
}

private struct Listener {
    var address: String
    var port: UInt16
    var state: String
    var inode: String
}

private func listeningAddresses(root: Int32, port: UInt16) throws -> [String] {
    var pids = [root]
    pids.append(contentsOf: descendants(of: root))
    var matches: [String] = []
    for pid in pids {
        let inodes = socketInodes(pid: pid)
        guard !inodes.isEmpty else { continue }
        let rows = parseTable("/proc/\(pid)/net/tcp") + parseTable("/proc/\(pid)/net/tcp6")
        for row in rows where row.state == "0A" && row.port == port && inodes.contains(row.inode) {
            matches.append(row.address)
        }
    }
    return matches
}

private func descendants(of root: Int32) -> [Int32] {
    var pending = ProcessTree.children(of: root)
    var all: [Int32] = []
    var seen = Set<Int32>()
    while let current = pending.popLast() {
        if !seen.insert(current).inserted {
            continue
        }
        all.append(current)
        pending.append(contentsOf: ProcessTree.children(of: current))
    }
    return all
}

private func socketInodes(pid: Int32) -> Set<String> {
    let directory = "/proc/\(pid)/fd"
    guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
        return []
    }
    var inodes = Set<String>()
    for name in names {
        let link = directory + "/" + name
        var buffer = [CChar](repeating: 0, count: 512)
        let length = readlink(link, &buffer, buffer.count - 1)
        if length < 0 {
            continue
        }
        buffer[Int(length)] = 0
        let text = String(cString: buffer)
        guard text.hasPrefix("socket:["), text.hasSuffix("]") else { continue }
        let inode = text.dropFirst("socket:[".count).dropLast()
        inodes.insert(String(inode))
    }
    return inodes
}

private func parseTable(_ path: String) -> [Listener] {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        return []
    }
    var rows: [Listener] = []
    for line in text.split(separator: "\n").dropFirst() {
        let fields = line.split(separator: " ").map(String.init)
        guard fields.count > 9 else { continue }
        let local = fields[1].split(separator: ":").map(String.init)
        guard local.count == 2, let port = UInt16(local[1], radix: 16) else { continue }
        rows.append(Listener(address: decodeAddress(local[0]), port: port, state: fields[3], inode: fields[9]))
    }
    return rows
}

private func decodeAddress(_ hex: String) -> String {
    if hex == "0100007F" {
        return "127.0.0.1"
    }
    if hex == "00000000000000000000000001000000" {
        return "::1"
    }
    if hex == "00000000" {
        return "0.0.0.0"
    }
    if hex == "00000000000000000000000000000000" {
        return "::"
    }
    return hex
}
