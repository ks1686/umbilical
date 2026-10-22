// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct DownloadStatus: Equatable {
    public enum State: String, Equatable {
        case active
        case waiting
        case paused
        case error
        case complete
        case removed
    }

    public let gid: String
    public let state: State
    public let totalLength: Int64
    public let completedLength: Int64
    public let downloadSpeed: Int64
    public let files: [URL]
    public let errorMessage: String?
}

private struct StatusRecord {
    var status: DownloadStatus
    var followedBy: String?
}

public final class RPCClient {
    let port: UInt16
    let secret: String
    let downloadDirectory: URL
    private let transport: any JSONRPCTransport
    private let quarantine: any QuarantineApplying
    private var marked: Set<String> = []

    init(
        port: UInt16,
        secret: String,
        downloadDirectory: URL,
        transport: any JSONRPCTransport,
        quarantine: any QuarantineApplying
    ) {
        self.port = port
        self.secret = secret
        self.downloadDirectory = downloadDirectory
        self.transport = transport
        self.quarantine = quarantine
    }

    public func add(url: URL, options: [String: String] = [:]) async throws -> String {
        let uri = try acceptedURI(url)
        try RPCOptionPolicy.validate(options, downloadRoot: downloadDirectory)
        let result = try await transport.call(
            method: "aria2.addUri",
            parameters: ["token:\(secret)", [uri], options]
        )
        guard let gid = result as? String, !gid.isEmpty else {
            throw EngineError.transport("addUri")
        }
        return gid
    }

    public func pause(gid: String) async throws {
        _ = try await transport.call(method: "aria2.pause", parameters: ["token:\(secret)", gid])
    }

    public func resume(gid: String) async throws {
        _ = try await transport.call(method: "aria2.unpause", parameters: ["token:\(secret)", gid])
    }

    public func remove(gid: String) async throws {
        _ = try await transport.call(method: "aria2.remove", parameters: ["token:\(secret)", gid])
    }

    public func changeOption(gid: String, options: [String: String]) async throws {
        try RPCOptionPolicy.validate(options, downloadRoot: downloadDirectory)
        _ = try await transport.call(
            method: "aria2.changeOption",
            parameters: ["token:\(secret)", gid, options]
        )
    }

    public func changeGlobalOption(_ options: [String: String]) async throws {
        try RPCOptionPolicy.validate(options, downloadRoot: downloadDirectory)
        _ = try await transport.call(
            method: "aria2.changeGlobalOption",
            parameters: ["token:\(secret)", options]
        )
    }

    public func addTorrent(file: URL, options: [String: String] = [:]) async throws -> String {
        try RPCOptionPolicy.validate(options, downloadRoot: downloadDirectory)
        let data = try TorrentMetadata.readFile(file)
        let metadata = try TorrentMetadata.parse(data)
        if let selection = options["select-file"] {
            try metadata.checkSelection(selection)
        }
        try metadata.checkContained(in: downloadDirectory)
        let encoded = data.base64EncodedString()
        let uris: [String] = []
        let result = try await transport.call(
            method: "aria2.addTorrent",
            parameters: ["token:\(secret)", encoded, uris, options]
        )
        guard let gid = result as? String, !gid.isEmpty else {
            throw EngineError.transport("addTorrent")
        }
        return gid
    }

    public func addMetalink(file: URL, options: [String: String] = [:]) async throws -> String {
        _ = file
        try RPCOptionPolicy.validate(options, downloadRoot: downloadDirectory)
        throw EngineError.notSupported("metalink")
    }

    public func status(gid: String) async throws -> DownloadStatus {
        try await status(gid: gid, depth: 0)
    }

    private func status(gid: String, depth: Int) async throws -> DownloadStatus {
        let parsed = try await fetchStatus(gid)
        if let next = parsed.followedBy, depth < 4 {
            return try await status(gid: next, depth: depth + 1)
        }
        if parsed.status.state == .complete {
            try quarantineFinishedFiles(parsed.status.files)
        }
        return parsed.status
    }

    private func fetchStatus(_ gid: String) async throws -> StatusRecord {
        let result = try await transport.call(
            method: "aria2.tellStatus",
            parameters: [
                "token:\(secret)",
                gid,
                [
                    "gid",
                    "status",
                    "totalLength",
                    "completedLength",
                    "downloadSpeed",
                    "errorMessage",
                    "files",
                    "followedBy"
                ]
            ]
        )
        return try Self.parseStatus(result)
    }

    func version() async throws -> String {
        let result = try await transport.call(
            method: "aria2.getVersion",
            parameters: ["token:\(secret)"]
        )
        guard let object = result as? [String: Any], let version = object["version"] as? String
        else {
            throw EngineError.transport("version")
        }
        return version
    }

    private func quarantineFinishedFiles(_ files: [URL]) throws {
        for file in files {
            let path = file.path
            if path.isEmpty || marked.contains(path) {
                continue
            }
            // Magnet metadata is an in-memory placeholder, not a file in dir.
            guard POSIX.isRegularFile(path) else { continue }
            _ = try DownloadPath.resolveInside(root: downloadDirectory, raw: path)
            try quarantine.markDownloaded(file: file)
            marked.insert(path)
        }
    }

    private func acceptedURI(_ url: URL) throws -> String {
        guard let scheme = url.scheme?.lowercased() else {
            throw EngineError.schemeRejected("")
        }
        switch scheme {
        case "http", "https", "ftp", "sftp":
            try HTTPURLPolicy.validateTransfer(url)
            let absolute = url.absoluteString
            if absolute.hasPrefix("-") {
                throw EngineError.schemeRejected("option")
            }
            return absolute
        case "magnet":
            return try MagnetLink.canonical(url)
        default:
            throw EngineError.schemeRejected(scheme)
        }
    }

    private static func parseStatus(_ result: Any) throws -> StatusRecord {
        guard let object = result as? [String: Any] else {
            throw EngineError.transport("status")
        }
        let gid = object["gid"] as? String ?? ""
        let status = object["status"] as? String ?? ""
        guard let state = DownloadStatus.State(rawValue: status) else {
            throw EngineError.unexpectedStatus(status)
        }
        var files: [URL] = []
        if let entries = object["files"] as? [[String: Any]] {
            for entry in entries {
                if let path = entry["path"] as? String, !path.isEmpty {
                    files.append(URL(fileURLWithPath: path))
                }
            }
        }
        let message = object["errorMessage"] as? String
        let record = DownloadStatus(
            gid: gid,
            state: state,
            totalLength: int64Value(object["totalLength"]),
            completedLength: int64Value(object["completedLength"]),
            downloadSpeed: int64Value(object["downloadSpeed"]),
            files: files,
            errorMessage: (message?.isEmpty == false) ? message : nil
        )
        return StatusRecord(status: record, followedBy: followedGID(object["followedBy"]))
    }

    private static func followedGID(_ value: Any?) -> String? {
        let list = value as? [Any] ?? []
        for item in list.reversed() {
            if let gid = item as? String, !gid.isEmpty {
                return gid
            }
        }
        return nil
    }

    private static func int64Value(_ value: Any?) -> Int64 {
        if let text = value as? String {
            return Int64(text) ?? 0
        }
        if let number = value as? Int64 {
            return number
        }
        if let number = value as? Int {
            return Int64(number)
        }
        if let number = value as? NSNumber {
            return number.int64Value
        }
        return 0
    }
}
