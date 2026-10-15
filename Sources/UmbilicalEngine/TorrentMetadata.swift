// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

struct TorrentMetadata {
    struct FileEntry {
        var components: [String]
        var length: Int64
    }

    enum Layout {
        case single(length: Int64)
        case multiple([FileEntry])
    }

    var name: String
    var layout: Layout
    var pieceLength: Int
    var totalLength: Int64

    var fileCount: Int {
        switch layout {
        case .single:
            return 1
        case .multiple(let files):
            return files.count
        }
    }

    var relativePaths: [String] {
        switch layout {
        case .single:
            return [name]
        case .multiple(let files):
            return files.map { entry in
                ([name] + entry.components).joined(separator: "/")
            }
        }
    }

    static func readFile(_ url: URL) throws -> Data {
        var info = stat()
        if stat(url.path, &info) != 0 {
            throw EngineError.torrentRejected("unreadable")
        }
        if (info.st_mode & S_IFMT) != S_IFREG {
            throw EngineError.torrentRejected("not a file")
        }
        if info.st_size <= 0 || info.st_size > 1_048_576 {
            throw EngineError.torrentRejected("size")
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw EngineError.torrentRejected("unreadable")
        }
        if data.count != Int(info.st_size) {
            throw EngineError.torrentRejected("size")
        }
        return data
    }

    static func parse(_ data: Data) throws -> TorrentMetadata {
        let root = try BEncodeParser.parse(data)
        guard case .dictionary = root else {
            throw EngineError.torrentRejected("bencode")
        }
        try rejectUnsafe(root)
        guard let info = root.lookup("info") else {
            throw EngineError.torrentRejected("info")
        }
        return try metadata(from: info)
    }

    func checkSelection(_ value: String) throws {
        for part in value.split(separator: ",") {
            guard let index = Int(part), (1...fileCount).contains(index) else {
                throw EngineError.optionValueRejected("select-file")
            }
        }
    }

    func checkContained(in root: URL) throws {
        for relative in relativePaths {
            _ = try DownloadPath.resolveInside(root: root, raw: relative)
        }
    }

    private static func metadata(from info: BEncoded) throws -> TorrentMetadata {
        guard case .dictionary = info else {
            throw EngineError.torrentRejected("info")
        }
        guard let name = info.lookup("name")?.utf8 else {
            throw EngineError.torrentRejected("name")
        }
        try validateComponent(name)
        guard
            let pieceLength64 = info.lookup("piece length")?.integer,
            let pieceLength = Int(exactly: pieceLength64),
            (1...(16 * 1024 * 1024)).contains(pieceLength)
        else {
            throw EngineError.torrentRejected("piece")
        }
        guard let pieces = info.lookup("pieces")?.bytes else {
            throw EngineError.torrentRejected("piece")
        }
        let layout = try layout(from: info)
        let total = try totalLength(of: layout)
        try validatePieces(pieces, total: total, pieceLength: pieceLength)
        return TorrentMetadata(
            name: name,
            layout: layout,
            pieceLength: pieceLength,
            totalLength: total
        )
    }

    private static func layout(from info: BEncoded) throws -> Layout {
        switch (info.lookup("files"), info.lookup("length")) {
        case (nil, .some(let value)):
            guard let size = value.integer, size >= 0 else {
                throw EngineError.torrentRejected("length")
            }
            return .single(length: size)
        case (.some(let value), nil):
            return .multiple(try fileEntries(value))
        default:
            throw EngineError.torrentRejected("info")
        }
    }

    private static func fileEntries(_ value: BEncoded) throws -> [FileEntry] {
        guard let items = value.list, !items.isEmpty, items.count <= 4096 else {
            throw EngineError.torrentRejected("file")
        }
        var entries: [FileEntry] = []
        for item in items {
            guard let length = item.lookup("length")?.integer, length >= 0 else {
                throw EngineError.torrentRejected("length")
            }
            guard let components = item.lookup("path")?.list, !components.isEmpty else {
                throw EngineError.torrentRejected("path")
            }
            var parts: [String] = []
            for component in components {
                guard let text = component.utf8 else {
                    throw EngineError.torrentRejected("path")
                }
                try validateComponent(text)
                parts.append(text)
            }
            entries.append(FileEntry(components: parts, length: length))
        }
        return entries
    }

    private static func totalLength(of layout: Layout) throws -> Int64 {
        switch layout {
        case .single(let length):
            return length
        case .multiple(let files):
            var total: Int64 = 0
            for file in files {
                let (sum, overflow) = total.addingReportingOverflow(file.length)
                if overflow {
                    throw EngineError.torrentRejected("length")
                }
                total = sum
            }
            return total
        }
    }

    private static func validatePieces(_ pieces: Data, total: Int64, pieceLength: Int) throws {
        let count: Int
        if total == 0 {
            count = 0
        } else {
            let width = Int64(pieceLength)
            guard let exact = Int(exactly: (total + width - 1) / width) else {
                throw EngineError.torrentRejected("piece")
            }
            count = exact
        }
        if pieces.count != count * 20 {
            throw EngineError.torrentRejected("piece")
        }
    }

    private static func validateComponent(_ component: String) throws {
        do {
            try DownloadPath.validateOutputName(component)
        } catch {
            throw EngineError.torrentRejected("name")
        }
        if component.utf8.count > 255 {
            throw EngineError.torrentRejected("name")
        }
        let controls = component.unicodeScalars.contains { scalar in
            scalar.value < 0x20 || scalar.value == 0x7F
        }
        if controls {
            throw EngineError.torrentRejected("name")
        }
    }

    private static func rejectUnsafe(_ value: BEncoded) throws {
        switch value {
        case .integer, .data:
            return
        case .list(let items):
            for item in items {
                try rejectUnsafe(item)
            }
        case .dictionary(let pairs):
            for (key, item) in pairs {
                switch key {
                case "url-list", "httpseeds":
                    try validateWebSeedValue(item)
                case "announce":
                    guard let text = item.utf8 else {
                        throw EngineError.torrentRejected("tracker")
                    }
                    try validateLocation(text, schemes: ["http", "https", "udp"], kind: "tracker")
                case "announce-list":
                    try validateAnnounceList(item)
                default:
                    try rejectUnsafe(item)
                }
            }
        }
    }

    private static func validateWebSeedValue(_ value: BEncoded) throws {
        switch value {
        case .data:
            guard let text = value.utf8 else {
                throw EngineError.torrentRejected("web-seed")
            }
            try validateLocation(text, schemes: ["http", "https"], kind: "web-seed")
        case .list(let items):
            if items.isEmpty {
                throw EngineError.torrentRejected("web-seed")
            }
            for item in items {
                guard let text = item.utf8 else {
                    throw EngineError.torrentRejected("web-seed")
                }
                try validateLocation(text, schemes: ["http", "https"], kind: "web-seed")
            }
        case .integer, .dictionary:
            throw EngineError.torrentRejected("web-seed")
        }
    }

    private static func validateAnnounceList(_ value: BEncoded) throws {
        guard let tiers = value.list else {
            throw EngineError.torrentRejected("tracker")
        }
        for tier in tiers {
            guard let trackers = tier.list, !trackers.isEmpty else {
                throw EngineError.torrentRejected("tracker")
            }
            for tracker in trackers {
                guard let text = tracker.utf8 else {
                    throw EngineError.torrentRejected("tracker")
                }
                try validateLocation(text, schemes: ["http", "https", "udp"], kind: "tracker")
            }
        }
    }

    private static func validateLocation(
        _ text: String,
        schemes: Set<String>,
        kind: String
    ) throws {
        if text.isEmpty || text.count > 2048 {
            throw EngineError.torrentRejected(kind)
        }
        if text.contains("\n") || text.contains("\r") || text.contains("\0") {
            throw EngineError.torrentRejected(kind)
        }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else {
            throw EngineError.torrentRejected(kind)
        }
        if !schemes.contains(scheme) || url.user != nil || url.password != nil {
            throw EngineError.torrentRejected(kind)
        }
        if url.host?.isEmpty != false {
            throw EngineError.torrentRejected(kind)
        }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.contains("..") || parts.contains(".") {
            throw EngineError.torrentRejected(kind)
        }
    }
}
