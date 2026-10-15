// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@testable import UmbilicalEngine

final class LocalHTTPServer {
    let port: UInt16
    private let body: Data
    private let hold: Bool
    private let listenFD: Int32
    private let condition = NSCondition()
    private var released = false
    private var running = true
    private var handlers = 0
    private let stopped = DispatchSemaphore(value: 0)

    init(body: Data, hold: Bool) throws {
        self.body = body
        self.hold = hold
        let listened = try POSIX.listenLoopback()
        self.listenFD = listened.fd
        self.port = listened.port
    }

    func start() {
        Thread.detachNewThread { [self] in
            self.serve()
            self.stopped.signal()
        }
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }

    func stop() {
        condition.lock()
        running = false
        released = true
        condition.broadcast()
        condition.unlock()
        if let wake = try? POSIX.connectLoopback(port: port, timeoutSeconds: 1) {
            POSIX.closeFD(wake)
        }
        POSIX.closeFD(listenFD)
        condition.lock()
        let deadline = Date().addingTimeInterval(3)
        while handlers > 0 && Date() < deadline {
            _ = condition.wait(until: Date().addingTimeInterval(0.2))
        }
        condition.unlock()
        _ = stopped.wait(timeout: .now() + 2)
    }

    private func serve() {
        while true {
            guard let client = POSIX.acceptClient(listenFD) else {
                break
            }
            condition.lock()
            let keepGoing = running
            if keepGoing {
                handlers += 1
            }
            condition.unlock()
            if !keepGoing {
                POSIX.closeFD(client)
                break
            }
            Thread.detachNewThread { [self] in
                self.handle(client)
                POSIX.closeFD(client)
                self.finishHandler()
            }
        }
    }

    private func finishHandler() {
        condition.lock()
        handlers -= 1
        condition.broadcast()
        condition.unlock()
    }

    private func handle(_ client: Int32) {
        POSIX.ignorePipe(client)
        _ = try? POSIX.setReceiveTimeout(fd: client, seconds: 5)
        _ = try? POSIX.setSendTimeout(fd: client, seconds: 5)
        let request = readRequest(client)
        let prepared = preparedResponse(for: request)
        if prepared.body.isEmpty {
            _ = try? POSIX.sendAll(fd: client, data: Data(prepared.header.utf8))
            return
        }
        var offset = 0
        while offset < prepared.body.count {
            condition.lock()
            let dump = released || !hold
            condition.unlock()
            let size = dump ? prepared.body.count - offset : min(4096, prepared.body.count - offset)
            let chunk = prepared.body.subdata(in: offset..<(offset + size))
            let outgoing: Data
            if offset == 0 {
                var payload = Data(prepared.header.utf8)
                payload.append(chunk)
                outgoing = payload
            } else {
                outgoing = chunk
            }
            guard (try? POSIX.sendAll(fd: client, data: outgoing)) != nil else {
                return
            }
            offset += size
            if dump || offset >= prepared.body.count {
                break
            }
            condition.lock()
            if !released {
                _ = condition.wait(until: Date().addingTimeInterval(0.25))
            }
            condition.unlock()
        }
    }

    private func readRequest(_ client: Int32) -> Data {
        var request = Data()
        let marker = Data("\r\n\r\n".utf8)
        while request.range(of: marker) == nil && request.count < 65536 {
            guard let chunk = try? POSIX.readOnce(fd: client, max: 4096), !chunk.isEmpty else {
                break
            }
            request.append(chunk)
        }
        return request
    }

    private func preparedResponse(for request: Data) -> (header: String, body: Data) {
        let text = String(bytes: request, encoding: .utf8) ?? ""
        if let range = byteRange(in: text), range.lowerBound < body.count {
            let end = min(range.upperBound, body.count)
            let slice = body.subdata(in: range.lowerBound..<end)
            let last = range.lowerBound + slice.count - 1
            let header = [
                "HTTP/1.1 206 Partial Content",
                "Content-Length: \(slice.count)",
                "Content-Range: bytes \(range.lowerBound)-\(last)/\(body.count)",
                "Content-Type: application/octet-stream",
                "Connection: close",
                "",
                ""
            ].joined(separator: "\r\n")
            return (header, slice)
        }
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Length: \(body.count)",
            "Content-Type: application/octet-stream",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        return (header, body)
    }

    private func byteRange(in request: String) -> Range<Int>? {
        for line in request.split(separator: "\r\n", omittingEmptySubsequences: false) {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                .map(String.init)
            guard parts.count == 2 else { continue }
            let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            guard name == "range" else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard value.lowercased().hasPrefix("bytes=") else { continue }
            let spec = value.dropFirst("bytes=".count)
            let bounds = spec.split(
                separator: "-",
                maxSplits: 1,
                omittingEmptySubsequences: false
            ).map(String.init)
            guard let start = bounds.first.flatMap(Int.init), start >= 0 else { continue }
            let end: Int
            if bounds.count == 2, !bounds[1].isEmpty, let parsed = Int(bounds[1]), parsed >= start {
                end = parsed + 1
            } else {
                end = body.count
            }
            return start..<end
        }
        return nil
    }
}
