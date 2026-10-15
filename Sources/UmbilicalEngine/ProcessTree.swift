// SPDX-License-Identifier: GPL-3.0-or-later

import CProc
import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum ProcessTree {
    static func lossyText(_ data: Data) -> String {
        let units: [UInt8] = data.withUnsafeBytes { raw in
            var copy: [UInt8] = []
            copy.reserveCapacity(raw.count)
            for byte in raw {
                let printable = byte == 0 || (byte >= 0x20 && byte < 0x7F)
                copy.append(printable ? byte : 0x3F)
            }
            return copy
        }
        return String(bytes: units, encoding: .utf8) ?? ""
    }

    static func containsSecret(root pid: Int32, secret: String) -> Bool {
        guard !secret.isEmpty else { return false }
        let deadline = Date().addingTimeInterval(1)
        while true {
            if snapshot(root: pid).contains(where: { $0.contains(secret) }) {
                return true
            }
            if !children(of: pid).isEmpty || Date() >= deadline {
                return snapshot(root: pid).contains(where: { $0.contains(secret) })
            }
            usleep(20_000)
        }
    }

    static func commandLines(root pid: Int32) -> [String] {
        var lines: [String] = []
        var pending = [pid]
        var seen = Set<Int32>()
        while let current = pending.popLast() {
            if !seen.insert(current).inserted {
                continue
            }
            if let line = commandLine(pid: current) {
                lines.append(line)
            }
            pending.append(contentsOf: children(of: current))
        }
        return lines
    }

    static func snapshot(root pid: Int32) -> [String] {
        var blobs: [String] = []
        var pending = [pid]
        var seen = Set<Int32>()
        while let current = pending.popLast() {
            if !seen.insert(current).inserted {
                continue
            }
            if let line = commandLine(pid: current) {
                blobs.append(line)
            }
            if let env = environment(pid: current) {
                blobs.append(env)
            }
            pending.append(contentsOf: children(of: current))
        }
        return blobs
    }

    static func children(of parent: Int32) -> [Int32] {
        #if os(Linux)
            return linuxChildren(of: parent)
        #else
            return darwinChildren(of: parent)
        #endif
    }

    static func commandLine(pid: Int32) -> String? {
        #if os(Linux)
            return nullSeparated(path: "/proc/\(pid)/cmdline")
        #else
            return darwinArguments(pid: pid)
        #endif
    }

    private static func environment(pid: Int32) -> String? {
        #if os(Linux)
            return nullSeparated(path: "/proc/\(pid)/environ")
        #else
            return nil
        #endif
    }

    #if os(Linux)
        private static func nullSeparated(path: String) -> String? {
            guard let data = FileManager.default.contents(atPath: path), !data.isEmpty else {
                return nil
            }
            return lossyText(data)
        }

        private static func linuxChildren(of parent: Int32) -> [Int32] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
                return []
            }
            var found: [Int32] = []
            for name in names {
                guard let pid = Int32(name), let ppid = parentPID(pid), ppid == parent else {
                    continue
                }
                found.append(pid)
            }
            return found
        }

        private static func parentPID(_ pid: Int32) -> Int32? {
            guard let text = try? String(contentsOfFile: "/proc/\(pid)/stat", encoding: .utf8),
                let end = text.lastIndex(of: ")")
            else {
                return nil
            }
            let fields = text[text.index(after: end)...].split(separator: " ")
            guard fields.count > 1 else { return nil }
            return Int32(fields[1])
        }
    #else
        private static func darwinChildren(of parent: Int32) -> [Int32] {
            let reported = umb_list_child_pids(parent, nil, 0)
            if reported <= 0 {
                return []
            }
            var buffer = [pid_t](repeating: 0, count: Int(reported))
            let written = buffer.withUnsafeMutableBytes { raw -> Int32 in
                guard let base = raw.baseAddress else { return 0 }
                return umb_list_child_pids(parent, base, Int32(raw.count))
            }
            if written <= 0 {
                return []
            }
            let pidSize = Int32(MemoryLayout<pid_t>.size)
            let pidCount: Int
            if written <= Int32(buffer.count) {
                pidCount = Int(written)
            } else if pidSize > 0, written % pidSize == 0 {
                pidCount = min(Int(written / pidSize), buffer.count)
            } else {
                return []
            }
            return buffer.prefix(pidCount).filter { $0 > 0 }
        }

        private static func darwinArguments(pid: pid_t) -> String? {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            let probed = mib.withUnsafeMutableBufferPointer { pointer -> Int32 in
                guard let base = pointer.baseAddress else { return -1 }
                return sysctl(base, UInt32(pointer.count), nil, &size, nil, 0)
            }
            if probed != 0 || size <= 0 {
                return nil
            }
            var buffer = [UInt8](repeating: 0, count: size)
            let copied = buffer.withUnsafeMutableBytes { raw -> Int32 in
                mib.withUnsafeMutableBufferPointer { pointer -> Int32 in
                    guard let name = pointer.baseAddress else { return -1 }
                    return sysctl(name, UInt32(pointer.count), raw.baseAddress, &size, nil, 0)
                }
            }
            if copied != 0 || size < MemoryLayout<Int32>.size {
                return nil
            }
            let argc = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
            if argc <= 0 {
                return nil
            }
            var offset = MemoryLayout<Int32>.size
            while offset < size && buffer[offset] != 0 {
                offset += 1
            }
            while offset < size && buffer[offset] == 0 {
                offset += 1
            }
            var parts: [String] = []
            while parts.count < Int(argc) && offset < size {
                let start = offset
                while offset < size && buffer[offset] != 0 {
                    offset += 1
                }
                if let text = String(bytes: buffer[start..<offset], encoding: .utf8) {
                    parts.append(text)
                }
                offset += 1
            }
            return parts.joined(separator: "\0")
        }
    #endif
}
