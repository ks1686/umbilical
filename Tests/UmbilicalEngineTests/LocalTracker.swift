// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@testable import UmbilicalEngine

final class LocalTracker {
    let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private let stopped = DispatchSemaphore(value: 0)
    private var injected: [UInt16]
    private var announced: [UInt16] = []
    private var running = true
    private var handlers = 0

    init(injected: [UInt16]) throws {
        self.injected = injected
        let listened = try POSIX.listenLoopback()
        self.listenFD = listened.fd
        self.port = listened.port
    }

    func start() {
        Thread.detachNewThread { [self] in
            self.acceptLoop()
            self.stopped.signal()
        }
    }

    func inject(_ port: UInt16) {
        lock.lock()
        if !injected.contains(port) {
            injected.append(port)
        }
        lock.unlock()
    }

    func announcedPorts() -> [UInt16] {
        lock.lock()
        let copy = announced
        lock.unlock()
        return copy
    }

    func stop() {
        lock.lock()
        running = false
        lock.unlock()
        if let wake = try? POSIX.connectLoopback(port: port, timeoutSeconds: 1) {
            POSIX.closeFD(wake)
        }
        POSIX.closeFD(listenFD)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            lock.lock()
            let pending = handlers
            lock.unlock()
            if pending == 0 {
                break
            }
            usleep(50_000)
        }
        _ = stopped.wait(timeout: .now() + 2)
    }

    static func body(ports: [UInt16]) -> Data {
        var peers = Data()
        for port in ports {
            peers.append(contentsOf: [127, 0, 0, 1])
            peers.append(UInt8(port >> 8))
            peers.append(UInt8(port & 0xFF))
        }
        var body = Data()
        let prefix =
            "d8:completei1e10:incompletei1e8:intervali1e12:min intervali1e5:peers"
        body.append(contentsOf: prefix.utf8)
        body.append(contentsOf: "\(peers.count):".utf8)
        body.append(peers)
        body.append(contentsOf: "e".utf8)
        return body
    }

    private func acceptLoop() {
        while stillRunning() {
            guard let client = POSIX.acceptClient(listenFD) else {
                break
            }
            if !beginHandler() {
                POSIX.closeFD(client)
                break
            }
            Thread.detachNewThread { [self] in
                self.respond(client)
                POSIX.closeFD(client)
                self.endHandler()
            }
        }
    }

    private func respond(_ client: Int32) {
        POSIX.ignorePipe(client)
        _ = try? POSIX.setReceiveTimeout(fd: client, seconds: 2)
        _ = try? POSIX.setSendTimeout(fd: client, seconds: 2)
        let request = readHeaders(client)
        let response = reply(to: request)
        _ = try? POSIX.sendAll(fd: client, data: response)
    }

    private func reply(to request: Data) -> Data {
        let text = String(bytes: request, encoding: .utf8) ?? ""
        guard let line = text.split(separator: "\r\n").first else {
            return http(status: 404, body: Data("not found".utf8))
        }
        let parts = line.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET" else {
            return http(status: 404, body: Data("not found".utf8))
        }
        let target = String(parts[1])
        guard target == "/announce" || target.hasPrefix("/announce?") else {
            return http(status: 404, body: Data("not found".utf8))
        }
        let query = queryMap(target)
        let event = query["event"] ?? ""
        let remotePort = UInt16(query["port"] ?? "") ?? 0
        record(port: remotePort, event: event)
        let peers = peerPorts(excluding: remotePort)
        return http(status: 200, body: LocalTracker.body(ports: peers))
    }

    private func peerPorts(excluding port: UInt16) -> [UInt16] {
        lock.lock()
        var ports = injected
        for item in announced where !ports.contains(item) {
            ports.append(item)
        }
        lock.unlock()
        return ports.filter { $0 != port && $0 > 0 }
    }

    private func record(port: UInt16, event: String) {
        guard port > 0 else {
            return
        }
        lock.lock()
        if event == "stopped" {
            announced.removeAll { $0 == port }
        } else if !announced.contains(port) {
            announced.append(port)
        }
        lock.unlock()
    }

    private func stillRunning() -> Bool {
        lock.lock()
        let value = running
        lock.unlock()
        return value
    }

    private func beginHandler() -> Bool {
        lock.lock()
        let keep = running
        if keep {
            handlers += 1
        }
        lock.unlock()
        return keep
    }

    private func endHandler() {
        lock.lock()
        handlers -= 1
        lock.unlock()
    }
}

private func readHeaders(_ client: Int32) -> Data {
    var request = Data()
    let marker = Data("\r\n\r\n".utf8)
    while request.range(of: marker) == nil && request.count < 65_536 {
        guard let chunk = try? POSIX.readOnce(fd: client, max: 4096), !chunk.isEmpty else {
            break
        }
        request.append(chunk)
    }
    return request
}

private func queryMap(_ target: String) -> [String: String] {
    guard let mark = target.firstIndex(of: "?") else {
        return [:]
    }
    let query = target[target.index(after: mark)...]
    var map: [String: String] = [:]
    for pair in query.split(separator: "&") {
        let bits = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard bits.count == 2 else {
            continue
        }
        map[String(bits[0])] = String(bits[1])
    }
    return map
}

private func http(status: Int, body: Data) -> Data {
    let reason = status == 200 ? "OK" : "Not Found"
    let head = [
        "HTTP/1.1 \(status) \(reason)",
        "Content-Type: text/plain",
        "Content-Length: \(body.count)",
        "Connection: close",
        "",
        ""
    ].joined(separator: "\r\n")
    var data = Data(head.utf8)
    data.append(body)
    return data
}
