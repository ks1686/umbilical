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
        try validateHTTP(url)
        try RPCOptionPolicy.validate(options, downloadRoot: downloadDirectory)
        let result = try await transport.call(
            method: "aria2.addUri",
            parameters: ["token:\(secret)", [url.absoluteString], options]
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
        _ = file
        try RPCOptionPolicy.validate(options, downloadRoot: downloadDirectory)
        throw EngineError.notSupported("torrent")
    }

    public func addMetalink(file: URL, options: [String: String] = [:]) async throws -> String {
        _ = file
        try RPCOptionPolicy.validate(options, downloadRoot: downloadDirectory)
        throw EngineError.notSupported("metalink")
    }

    public func status(gid: String) async throws -> DownloadStatus {
        let result = try await transport.call(
            method: "aria2.tellStatus",
            parameters: [
                "token:\(secret)",
                gid,
                ["gid", "status", "totalLength", "completedLength", "downloadSpeed", "errorMessage", "files"],
            ]
        )
        let parsed = try Self.parseStatus(result)
        if parsed.state == .complete {
            try quarantineFinishedFiles(parsed.files)
        }
        return parsed
    }

    func version() async throws -> String {
        let result = try await transport.call(
            method: "aria2.getVersion",
            parameters: ["token:\(secret)"]
        )
        guard let object = result as? [String: Any], let version = object["version"] as? String else {
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
            _ = try DownloadPath.resolveInside(root: downloadDirectory, raw: path)
            guard POSIX.isRegularFile(path) else { continue }
            try quarantine.markDownloaded(file: file)
            marked.insert(path)
        }
    }

    private func validateHTTP(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased() else {
            throw EngineError.schemeRejected("")
        }
        guard scheme == "http" || scheme == "https" else {
            throw EngineError.schemeRejected(scheme)
        }
        if url.user != nil || url.password != nil {
            throw EngineError.schemeRejected("userinfo")
        }
        guard let host = url.host, !host.isEmpty else {
            throw EngineError.schemeRejected(scheme)
        }
        let absolute = url.absoluteString
        if absolute.contains("\n") || absolute.contains("\r") || absolute.contains("\0") {
            throw EngineError.schemeRejected(scheme)
        }
    }

    private static func parseStatus(_ result: Any) throws -> DownloadStatus {
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
        return DownloadStatus(
            gid: gid,
            state: state,
            totalLength: int64Value(object["totalLength"]),
            completedLength: int64Value(object["completedLength"]),
            downloadSpeed: int64Value(object["downloadSpeed"]),
            files: files,
            errorMessage: (message?.isEmpty == false) ? message : nil
        )
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
