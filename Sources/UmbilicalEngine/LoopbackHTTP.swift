// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct HTTPMessage {
    var status: Int
    var headers: [String: String]
    var body: Data
    var raw: Data
}

enum LoopbackHTTP {
    static func post(
        port: UInt16,
        body: Data,
        headers: [String: String] = [:],
        timeoutSeconds: Int = 5
    ) throws -> HTTPMessage {
        var head = "POST /jsonrpc HTTP/1.1\r\n"
        head += "Host: 127.0.0.1:\(port)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n"
        for (name, value) in headers {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var request = Data(head.utf8)
        request.append(body)
        let raw = try exchange(port: port, request: request, timeoutSeconds: timeoutSeconds)
        return try parse(raw)
    }

    static func exchange(port: UInt16, request: Data, timeoutSeconds: Int = 5) throws -> Data {
        let fd = try POSIX.connectLoopback(port: port, timeoutSeconds: timeoutSeconds)
        defer { POSIX.closeFD(fd) }
        try POSIX.sendAll(fd: fd, data: request)
        var buffer = Data()
        while buffer.count < 2_000_000 {
            guard let chunk = try POSIX.readOnce(fd: fd, max: 8192) else {
                break
            }
            if chunk.isEmpty {
                continue
            }
            buffer.append(chunk)
            if responseComplete(buffer) {
                break
            }
        }
        if buffer.isEmpty {
            throw EngineError.transport("empty response")
        }
        return buffer
    }

    static func parse(_ raw: Data) throws -> HTTPMessage {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = raw.range(of: separator) else {
            throw EngineError.transport("truncated response")
        }
        let headerText = String(decoding: raw.subdata(in: raw.startIndex..<range.lowerBound), as: UTF8.self)
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let statusLine = lines.first else {
            throw EngineError.transport("missing status")
        }
        let fields = statusLine.split(separator: " ")
        guard fields.count >= 2, let status = Int(fields[1]) else {
            throw EngineError.transport("bad status")
        }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let split = line.firstIndex(of: ":") else { continue }
            let name = line[..<split].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: split)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }
        let body = raw.subdata(in: range.upperBound..<raw.endIndex)
        return HTTPMessage(status: status, headers: headers, body: body, raw: raw)
    }

    private static func responseComplete(_ buffer: Data) -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else {
            return false
        }
        let headerText = String(decoding: buffer.subdata(in: buffer.startIndex..<range.lowerBound), as: UTF8.self)
        let lines = headerText.split(separator: "\r\n").map(String.init)
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" else {
                continue
            }
            guard let length = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
                return false
            }
            return buffer.count >= range.upperBound + length
        }
        return false
    }
}

protocol JSONRPCTransport {
    func call(method: String, parameters: [Any]) async throws -> Any
}

struct LoopbackTransport: JSONRPCTransport {
    let port: UInt16
    var timeoutSeconds: Int = 5

    func call(method: String, parameters: [Any]) async throws -> Any {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": parameters,
        ]
        let body = try JSONSerialization.data(withJSONObject: payload)
        let message = try LoopbackHTTP.post(port: port, body: body, timeoutSeconds: timeoutSeconds)
        guard message.status == 200 else {
            throw EngineError.transport("http \(message.status)")
        }
        guard let object = try JSONSerialization.jsonObject(with: message.body) as? [String: Any] else {
            throw EngineError.transport("json")
        }
        if let error = object["error"] as? [String: Any] {
            let code = (error["code"] as? Int) ?? (error["code"] as? NSNumber)?.intValue ?? -1
            let text = error["message"] as? String ?? ""
            throw EngineError.rpc(code: code, message: text)
        }
        if let result = object["result"] {
            return result
        }
        throw EngineError.transport("missing result")
    }
}
