// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@testable import UmbilicalEngine

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum ProcessSocketError: Error, CustomStringConvertible {
    case unknownAddress(String)
    case unreadable(String)

    var description: String {
        switch self {
        case .unknownAddress(let value):
            return "unrecognized socket address \(value)"
        case .unreadable(let value):
            return "socket table unreadable: \(value)"
        }
    }
}

enum ProcessSockets {
    static func establishedRemotes(root: Int32) throws -> [String] {
        #if os(Linux)
            return try linuxRemotes(root: root)
        #else
            return try macRemotes(root: root)
        #endif
    }
}

#if os(Linux)
    private func linuxRemotes(root: Int32) throws -> [String] {
        var found: [String] = []
        for pid in processIDs(root: root) {
            let inodes = socketInodes(pid: pid)
            if inodes.isEmpty {
                continue
            }
            let rows = socketRows("/proc/\(pid)/net/tcp") + socketRows("/proc/\(pid)/net/tcp6")
            for row in rows where row.state == "01" && inodes.contains(row.inode) {
                found.append(try decodeProcAddress(row.address))
            }
        }
        return found
    }

    private struct SocketRow {
        var address: String
        var state: String
        var inode: String
    }

    private func socketRows(_ path: String) -> [SocketRow] {
        let text = readSocketTable(path)
        if text.isEmpty {
            return []
        }
        var rows: [SocketRow] = []
        for line in text.split(separator: "\n").dropFirst() {
            let fields = line.split(separator: " ").map(String.init)
            guard fields.count > 9 else {
                continue
            }
            let remote = fields[2].split(separator: ":").map(String.init)
            guard remote.count == 2 else {
                continue
            }
            rows.append(SocketRow(address: remote[0], state: fields[3], inode: fields[9]))
        }
        return rows
    }

    // /proc/net/tcp is a seq_file whose size is reported as 0. One read returns
    // about 4KB and leaves the rest for the next read. String(contentsOfFile:)
    // stops early, which drops the established peer sockets.
    private func readSocketTable(_ path: String) -> String {
        let fd = open(path, O_RDONLY)
        if fd < 0 {
            return ""
        }
        defer { close(fd) }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = buffer.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else {
                    return -1
                }
                return read(fd, base, raw.count)
            }
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                return ""
            }
            if count == 0 {
                return String(bytes: data, encoding: .utf8) ?? ""
            }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private func socketInodes(pid: Int32) -> Set<String> {
        let directory = "/proc/\(pid)/fd"
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else {
            return []
        }
        var inodes = Set<String>()
        for name in names {
            guard let text = linkText(directory + "/" + name) else {
                continue
            }
            guard text.hasPrefix("socket:["), text.hasSuffix("]") else {
                continue
            }
            let inode = text.dropFirst("socket:[".count).dropLast()
            inodes.insert(String(inode))
        }
        return inodes
    }

    private func linkText(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: 512)
        let length = readlink(path, &buffer, buffer.count - 1)
        if length < 0 {
            return nil
        }
        buffer[Int(length)] = 0
        return String(cString: buffer)
    }

    private func decodeProcAddress(_ hex: String) throws -> String {
        if hex.count == 8 {
            return try decodeProcIPv4(hex)
        }
        if hex.count == 32 {
            return try decodeProcIPv6(hex)
        }
        throw ProcessSocketError.unknownAddress(hex)
    }

    private func decodeProcIPv4(_ hex: String) throws -> String {
        let bytes = try hexBytes(hex)
        guard bytes.count == 4 else {
            throw ProcessSocketError.unknownAddress(hex)
        }
        return "\(bytes[3]).\(bytes[2]).\(bytes[1]).\(bytes[0])"
    }

    private func decodeProcIPv6(_ hex: String) throws -> String {
        let raw = try hexBytes(hex)
        guard raw.count == 16 else {
            throw ProcessSocketError.unknownAddress(hex)
        }
        var network: [UInt8] = []
        var offset = 0
        while offset < 16 {
            network.append(raw[offset + 3])
            network.append(raw[offset + 2])
            network.append(raw[offset + 1])
            network.append(raw[offset])
            offset += 4
        }
        if network == [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1] {
            return "::1"
        }
        return ipv6Text(network)
    }

    private func ipv6Text(_ bytes: [UInt8]) -> String {
        var groups: [String] = []
        var index = 0
        while index < 16 {
            let value = (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
            groups.append(String(value, radix: 16))
            index += 2
        }
        return groups.joined(separator: ":")
    }

    private func hexBytes(_ hex: String) throws -> [UInt8] {
        var bytes: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            guard let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) else {
                throw ProcessSocketError.unknownAddress(hex)
            }
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                throw ProcessSocketError.unknownAddress(hex)
            }
            bytes.append(byte)
            index = next
        }
        return bytes
    }
#else
    private func macRemotes(root: Int32) throws -> [String] {
        var found: [String] = []
        for pid in processIDs(root: root) {
            found.append(contentsOf: try lsofRemotes(pid: pid))
        }
        return found
    }

    private func lsofRemotes(pid: Int32) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-a", "-p", "\(pid)", "-iTCP"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(bytes: data, encoding: .utf8) else {
            throw ProcessSocketError.unreadable("lsof output was not utf-8")
        }
        if process.terminationStatus != 0 && text.isEmpty {
            throw ProcessSocketError.unreadable("lsof exited \(process.terminationStatus)")
        }
        var hosts: [String] = []
        for line in text.split(separator: "\n") {
            if let host = try remoteHost(String(line)) {
                hosts.append(host)
            }
        }
        return hosts
    }

    private func remoteHost(_ line: String) throws -> String? {
        guard line.contains("ESTABLISHED"), let arrow = line.range(of: "->") else {
            return nil
        }
        let after = line[arrow.upperBound...]
        guard let token = after.split(separator: " ").first else {
            throw ProcessSocketError.unknownAddress(line)
        }
        return hostOnly(String(token))
    }

    private func hostOnly(_ endpoint: String) -> String {
        if endpoint.hasPrefix("[") {
            guard let end = endpoint.firstIndex(of: "]") else {
                return endpoint
            }
            return String(endpoint[endpoint.index(after: endpoint.startIndex)..<end])
        }
        guard let colon = endpoint.lastIndex(of: ":") else {
            return endpoint
        }
        return String(endpoint[..<colon])
    }
#endif

private func processIDs(root: Int32) -> [Int32] {
    var pending = [root]
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
