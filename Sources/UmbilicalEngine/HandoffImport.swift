// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Copies or fetches a handoff file into the download folder after confirmation.
public enum HandoffImport {
    public static func fetchTorrent(
        url: URL,
        filename: String?,
        directory: URL
    ) async throws -> URL {
        let data = try await CookieFreeHTTP.get(url)
        _ = try TorrentMetadata.parse(data)
        let name = try acceptedName(filename, url: url, fallback: "download.torrent")
        return try write(data, named: name, into: directory)
    }

    public static func copyLocal(
        url: URL,
        filename: String?,
        directory: URL,
        torrent: Bool
    ) throws -> URL {
        let fallback = torrent ? "download.torrent" : "download.metalink"
        let name = try acceptedName(filename, url: url, fallback: fallback)
        if torrent {
            let data = try TorrentMetadata.readFile(url)
            _ = try TorrentMetadata.parse(data)
        }
        if let existing = try? DownloadPath.resolveInside(root: directory, raw: url.path) {
            let same = URL(fileURLWithPath: existing)
            if same.lastPathComponent == name {
                return same
            }
        }
        let destination = try uniqueDestination(named: name, in: directory)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            throw EngineError.handoffRejected("copy")
        }
        _ = try DownloadPath.resolveInside(root: directory, raw: destination.path)
        if torrent {
            let data = try TorrentMetadata.readFile(destination)
            _ = try TorrentMetadata.parse(data)
        }
        return destination
    }

    private static func write(_ data: Data, named name: String, into directory: URL) throws -> URL {
        let destination = try uniqueDestination(named: name, in: directory)
        do {
            try data.write(to: destination, options: .withoutOverwriting)
        } catch {
            throw EngineError.handoffRejected("copy")
        }
        _ = try DownloadPath.resolveInside(root: directory, raw: destination.path)
        return destination
    }

    private static func uniqueDestination(named name: String, in directory: URL) throws -> URL {
        try DownloadPath.validateOutputName(name)
        let url = directory.appendingPathComponent(name)
        if !FileManager.default.fileExists(atPath: url.path) {
            return url
        }
        let base = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let ext = URL(fileURLWithPath: name).pathExtension
        for index in 2...99 {
            let candidateName: String
            if ext.isEmpty {
                candidateName = "\(base)-\(index)"
            } else {
                candidateName = "\(base)-\(index).\(ext)"
            }
            try DownloadPath.validateOutputName(candidateName)
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        throw EngineError.outputNameRejected(name)
    }

    private static func acceptedName(_ outputName: String?, url: URL, fallback: String) throws -> String {
        if let outputName, !outputName.isEmpty {
            return try plainName(outputName)
        }
        let last = url.lastPathComponent
        if last.isEmpty || last == "/" {
            return try plainName(fallback)
        }
        return try plainName(last)
    }

    private static func plainName(_ name: String) throws -> String {
        if name.hasPrefix("-") {
            throw EngineError.outputNameRejected(name)
        }
        try DownloadPath.validateOutputName(name)
        return name
    }
}
