// SPDX-License-Identifier: GPL-3.0-or-later

import CXAttr
import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public protocol QuarantineApplying {
    func markDownloaded(file: URL) throws
}

public struct SystemQuarantine: QuarantineApplying {
    public init() {}

    public func markDownloaded(file: URL) throws {
        let value = QuarantineMark.value(at: Date())
        try QuarantineMark.set(value, on: file.path)
    }
}

enum QuarantineMark {
    static let attributeName = "com.apple.quarantine"

    static func value(at date: Date) -> String {
        let seconds = Int(date.timeIntervalSince1970)
        let stamp = String(seconds, radix: 16)
        return "0083;\(stamp);umbilical;\(UUID().uuidString.lowercased())"
    }

    static func set(_ value: String, on path: String) throws {
        let bytes = Array(value.utf8)
        let result = bytes.withUnsafeBytes { buffer -> Int32 in
            guard let base = buffer.baseAddress else { return -1 }
            return umb_setxattr(path, attributeName, base, buffer.count)
        }
        if result != 0 {
            throw EngineError.quarantineFailed(String(cString: strerror(errno)))
        }
    }

    static func read(path: String) throws -> String {
        let size = umb_getxattr(path, attributeName, nil, 0)
        if size < 0 {
            throw EngineError.quarantineFailed(String(cString: strerror(errno)))
        }
        var bytes = [UInt8](repeating: 0, count: Int(size))
        let result = bytes.withUnsafeMutableBytes { buffer -> ssize_t in
            guard let base = buffer.baseAddress else { return -1 }
            return umb_getxattr(path, attributeName, base, size_t(size))
        }
        if result < 0 {
            throw EngineError.quarantineFailed(String(cString: strerror(errno)))
        }
        return String(decoding: bytes.prefix(Int(result)), as: UTF8.self)
    }
}
