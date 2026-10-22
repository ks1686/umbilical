// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum DownloadPath {
    static func resolveInside(root: URL, raw: String) throws -> String {
        if raw.isEmpty || raw.contains("\0") || raw.contains("\n") || raw.contains("\r") || raw.contains("\\") {
            throw EngineError.directoryRejected(raw)
        }
        let rootReal = try existingRealPath(root.path)
        let absolute = raw.hasPrefix("/") ? raw : rootReal + "/" + raw
        let pieces = absolute.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if pieces.contains("..") || pieces.contains(".") {
            throw EngineError.directoryRejected(raw)
        }

        var existing = "/"
        var consumed = 0
        for (index, segment) in pieces.enumerated() {
            let next = existing == "/" ? "/" + segment : existing + "/" + segment
            var info = stat()
            if lstat(next, &info) == 0 {
                existing = next
                consumed = index + 1
            } else {
                break
            }
        }

        let resolvedExisting = try existingRealPath(existing)
        var finalPath = resolvedExisting
        for segment in pieces.dropFirst(consumed) {
            if finalPath == "/" {
                finalPath = "/" + segment
            } else {
                finalPath += "/" + segment
            }
        }
        if finalPath.count > 1 && finalPath.hasSuffix("/") {
            finalPath.removeLast()
        }
        if !isInside(rootReal: rootReal, path: finalPath) {
            throw EngineError.directoryRejected(raw)
        }
        return finalPath
    }

    static func validateOutputName(_ name: String) throws {
        if name.isEmpty || name == "." || name == ".." {
            throw EngineError.outputNameRejected(name)
        }
        if name.contains("/") || name.contains("\\") || name.contains("\0") || name.contains("\n") || name.contains("\r") {
            throw EngineError.outputNameRejected(name)
        }
    }

    static func validateSplit(_ value: String) throws {
        guard let number = Int(value), (1...128).contains(number) else {
            throw EngineError.optionValueRejected("split")
        }
    }

    static func validateRate(_ value: String) throws {
        let pattern = "^[1-9][0-9]*[KMGT]?$"
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw EngineError.optionValueRejected("max-download-limit")
        }
    }

    static func validateSelectFile(_ value: String) throws {
        let pattern = "^[1-9][0-9]*(,[1-9][0-9]*)*$"
        guard value.range(of: pattern, options: .regularExpression) != nil else {
            throw EngineError.optionValueRejected("select-file")
        }
    }

    static func validateFollowMetalink(_ value: String) throws {
        if value != "true" && value != "false" {
            throw EngineError.optionValueRejected("follow-metalink")
        }
    }

    /// Confirms `raw` is a regular file inside `root`. Symlinks, directories, and `..` are refused.
    static func deletableRegularFile(root: URL, raw: String) throws -> String {
        if raw.isEmpty || raw.contains("\0") || raw.contains("\n") || raw.contains("\r")
            || raw.contains("\\")
        {
            throw EngineError.directoryRejected(raw)
        }
        let rootReal = try existingRealPath(root.path)
        let absolute = raw.hasPrefix("/") ? raw : rootReal + "/" + raw
        let pieces = absolute.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        if pieces.contains("..") || pieces.contains(".") {
            throw EngineError.directoryRejected(raw)
        }
        var info = stat()
        if lstat(absolute, &info) != 0 {
            throw EngineError.directoryRejected(raw)
        }
        let type = info.st_mode & S_IFMT
        if type == S_IFLNK || type != S_IFREG {
            throw EngineError.directoryRejected(raw)
        }
        let resolved = try resolveInside(root: root, raw: raw)
        if lstat(resolved, &info) != 0 {
            throw EngineError.directoryRejected(raw)
        }
        let resolvedType = info.st_mode & S_IFMT
        if resolvedType == S_IFLNK || resolvedType != S_IFREG {
            throw EngineError.directoryRejected(raw)
        }
        return resolved
    }

    static func isInside(rootReal: String, path: String) -> Bool {
        if path == rootReal {
            return true
        }
        let prefix = rootReal.hasSuffix("/") ? rootReal : rootReal + "/"
        return path.hasPrefix(prefix)
    }

    private static func existingRealPath(_ path: String) throws -> String {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let resolved = buffer.withUnsafeMutableBufferPointer { pointer -> UnsafeMutablePointer<CChar>? in
            realpath(path, pointer.baseAddress)
        }
        if resolved == nil {
            throw EngineError.directoryRejected(path)
        }
        return buffer.withUnsafeBufferPointer { pointer in
            String(cString: pointer.baseAddress!)
        }
    }
}
