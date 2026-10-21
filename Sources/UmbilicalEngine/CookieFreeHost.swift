// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum CookieFreeHost {
    static let maxRedirects = 5

    static func validate(_ url: URL) throws {
        try HTTPURLPolicy.validate(url)
        try rejectPrivate(url)
    }

    static func acceptedHop(_ url: URL?, hops: Int) throws {
        guard let url else {
            throw EngineError.torrentRejected("fetch")
        }
        if hops > maxRedirects {
            throw EngineError.torrentRejected("fetch")
        }
        try validate(url)
    }

    static func rejectPrivate(_ url: URL) throws {
        guard let host = url.host, !host.isEmpty else {
            throw EngineError.torrentRejected("host")
        }
        let name = normalizedHost(host)
        if blockedName(name) || blockedAddress(name) {
            throw EngineError.torrentRejected("host")
        }
        if parseIPv4(name) != nil || parseIPv6(name) != nil {
            return
        }
        for address in try resolve(name) where blockedAddress(address) {
            throw EngineError.torrentRejected("host")
        }
    }

    static func blockedName(_ host: String) -> Bool {
        host == "localhost"
    }

    static func blockedAddress(_ host: String) -> Bool {
        if let value = parseIPv4(host) {
            return blockedIPv4(value)
        }
        if let bytes = parseIPv6(host) {
            return blockedIPv6(bytes)
        }
        return false
    }

    static func blockedIPv4(_ address: UInt32) -> Bool {
        if address == 0 { return true }
        let octet0 = address >> 24
        if octet0 == 10 || octet0 == 127 { return true }
        let prefix16 = address >> 16
        if prefix16 == 0xa9fe || prefix16 == 0xc0a8 { return true }
        return address >> 20 == 0xac1
    }

    static func blockedIPv6(_ bytes: [UInt8]) -> Bool {
        if bytes.count != 16 { return true }
        if bytes.allSatisfy({ $0 == 0 }) { return true }
        if isLoopbackV6(bytes) { return true }
        if bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80 { return true }
        if (bytes[0] & 0xfe) == 0xfc { return true }
        if let mapped = mappedIPv4(bytes) {
            return blockedIPv4(mapped)
        }
        return false
    }
}

extension CookieFreeHost {
    static func normalizedHost(_ host: String) -> String {
        var name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if let zone = name.firstIndex(of: "%") {
            name = String(name[..<zone])
        }
        while name.hasSuffix(".") {
            name.removeLast()
        }
        return name.lowercased()
    }

    static func parseIPv4(_ host: String) -> UInt32? {
        var address = in_addr()
        let ok = host.withCString { inet_pton(AF_INET, $0, &address) }
        guard ok == 1 else { return nil }
        return UInt32(bigEndian: address.s_addr)
    }

    static func parseIPv6(_ host: String) -> [UInt8]? {
        var address = in6_addr()
        let ok = host.withCString { inet_pton(AF_INET6, $0, &address) }
        guard ok == 1 else { return nil }
        return withUnsafeBytes(of: address) { Array($0.prefix(16)) }
    }

    static func isLoopbackV6(_ bytes: [UInt8]) -> Bool {
        bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
    }

    static func mappedIPv4(_ bytes: [UInt8]) -> UInt32? {
        let mapped =
            bytes.prefix(10).allSatisfy { $0 == 0 }
            && bytes[10] == 0xff && bytes[11] == 0xff
        let compatible = bytes.prefix(12).allSatisfy { $0 == 0 } && !isLoopbackV6(bytes)
        guard mapped || compatible else { return nil }
        return bytes[12...15].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    static func resolve(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
            hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
            hints.ai_socktype = SOCK_STREAM
        #endif
        var info: UnsafeMutablePointer<addrinfo>?
        let status = host.withCString { getaddrinfo($0, nil, &hints, &info) }
        guard status == 0, let first = info else {
            throw EngineError.torrentRejected("host")
        }
        defer { freeaddrinfo(first) }
        var found: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let current = cursor {
            if let text = numericAddress(current.pointee) {
                found.append(text)
            }
            cursor = current.pointee.ai_next
        }
        if found.isEmpty {
            throw EngineError.torrentRejected("host")
        }
        return found
    }

    static func numericAddress(_ info: addrinfo) -> String? {
        guard let addr = info.ai_addr else { return nil }
        if info.ai_family == AF_INET {
            return ipv4Text(addr)
        }
        if info.ai_family == AF_INET6 {
            return ipv6Text(addr)
        }
        return nil
    }

    static func ipv4Text(_ addr: UnsafePointer<sockaddr>) -> String? {
        var sin = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let ok = withUnsafePointer(to: &sin.sin_addr) { pointer in
            inet_ntop(AF_INET, pointer, &text, socklen_t(INET_ADDRSTRLEN))
        }
        return ok == nil ? nil : String(cString: text)
    }

    static func ipv6Text(_ addr: UnsafePointer<sockaddr>) -> String? {
        var sin6 = addr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
        var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        let ok = withUnsafePointer(to: &sin6.sin6_addr) { pointer in
            inet_ntop(AF_INET6, pointer, &text, socklen_t(INET6_ADDRSTRLEN))
        }
        return ok == nil ? nil : String(cString: text)
    }
}
