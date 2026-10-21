// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// How a confirmed handoff should start after the user accepts the sheet.
public enum ExtensionHandoffKind: String, Equatable {
    case download
    case video
    case torrentFile
    case metalinkFile
}

/// A link staged from the Safari extension, a Finder open, or an `umbilical://` URL.
/// Staging does not start a download. `ExternalDownload.confirm` does that.
public struct ExtensionHandoff: Equatable {
    public let uri: String
    public let outputName: String?
    public let url: URL
    public let kind: ExtensionHandoffKind

    public init(
        uri: String,
        outputName: String?,
        url: URL,
        kind: ExtensionHandoffKind = .download
    ) {
        self.uri = uri
        self.outputName = outputName
        self.url = url
        self.kind = kind
    }

    /// Aria2 options for this handoff. The only key is `out`, and only when a file name was accepted.
    public var options: [String: String] {
        guard let outputName else {
            return [:]
        }
        return ["out": outputName]
    }
}

/// A handoff the user has confirmed. The session accepts this and not a raw URL.
public struct ConfirmedExternalDownload: Equatable {
    public let uri: String
    public let outputName: String?
    public let url: URL
    public let options: [String: String]
    public let kind: ExtensionHandoffKind

    public init(
        uri: String,
        outputName: String?,
        url: URL,
        options: [String: String],
        kind: ExtensionHandoffKind = .download
    ) {
        self.uri = uri
        self.outputName = outputName
        self.url = url
        self.options = options
        self.kind = kind
    }
}

public enum ExternalDownload {
    public static let scheme = "umbilical"
    public static let host = "download"
    public static let videoHost = "video"
    /// Native messages and open-URL queries may carry only these fields.
    /// `video` is a routing flag from the extension UI, never from page text.
    public static let messageKeys: Set<String> = ["url", "filename", "video"]
    public static let queryKeys: Set<String> = ["url", "filename"]

    public static func stage(nativeMessage: Any, downloadRoot: URL) throws -> ExtensionHandoff {
        let parsed = try fields(from: nativeMessage)
        return try make(
            urlText: parsed.url,
            filename: parsed.filename,
            downloadRoot: downloadRoot,
            kind: parsed.video ? .video : .download
        )
    }

    public static func stage(openURL: URL, downloadRoot: URL) throws -> ExtensionHandoff {
        if openURL.isFileURL {
            return try stage(localFile: openURL, downloadRoot: downloadRoot)
        }
        if openURL.scheme?.lowercased() == "magnet" {
            return try make(
                urlText: openURL.absoluteString,
                filename: nil,
                downloadRoot: downloadRoot,
                kind: .download
            )
        }
        let parsed = try fields(from: openURL)
        return try make(
            urlText: parsed.url,
            filename: parsed.filename,
            downloadRoot: downloadRoot,
            kind: parsed.video ? .video : .download
        )
    }

    public static func stage(
        urlText: String,
        filename: String?,
        downloadRoot: URL
    ) throws -> ExtensionHandoff {
        try make(urlText: urlText, filename: filename, downloadRoot: downloadRoot, kind: .download)
    }

    public static func stage(
        urlText: String,
        filename: String?,
        downloadRoot: URL,
        kind: ExtensionHandoffKind
    ) throws -> ExtensionHandoff {
        try make(urlText: urlText, filename: filename, downloadRoot: downloadRoot, kind: kind)
    }

    public static func stage(localFile: URL, downloadRoot: URL) throws -> ExtensionHandoff {
        _ = downloadRoot
        guard localFile.isFileURL else {
            throw EngineError.schemeRejected(localFile.scheme?.lowercased() ?? "file")
        }
        if localFile.absoluteString.hasPrefix("-") {
            throw EngineError.schemeRejected("option")
        }
        let name = localFile.lastPathComponent
        try DownloadPath.validateOutputName(name)
        let ext = DownloadCaptureHint.pathExtension(url: localFile, filename: name) ?? ""
        if DownloadCaptureHint.torrentExtensions.contains(ext) {
            let data = try TorrentMetadata.readFile(localFile)
            _ = try TorrentMetadata.parse(data)
            return ExtensionHandoff(
                uri: localFile.absoluteString,
                outputName: name,
                url: localFile,
                kind: .torrentFile
            )
        }
        if DownloadCaptureHint.metalinkExtensions.contains(ext) {
            try validateMetalinkFile(localFile)
            return ExtensionHandoff(
                uri: localFile.absoluteString,
                outputName: name,
                url: localFile,
                kind: .metalinkFile
            )
        }
        throw EngineError.handoffRejected("type")
    }

    public static func confirm(
        _ handoff: ExtensionHandoff,
        downloadRoot: URL
    ) throws -> ConfirmedExternalDownload {
        let staged: ExtensionHandoff
        switch handoff.kind {
        case .torrentFile, .metalinkFile:
            staged = try stage(localFile: handoff.url, downloadRoot: downloadRoot)
            guard staged.kind == handoff.kind else {
                throw EngineError.handoffRejected("type")
            }
        case .download, .video:
            staged = try make(
                urlText: handoff.uri,
                filename: handoff.outputName,
                downloadRoot: downloadRoot,
                kind: handoff.kind
            )
        }
        return ConfirmedExternalDownload(
            uri: staged.uri,
            outputName: staged.outputName,
            url: staged.url,
            options: staged.options,
            kind: staged.kind
        )
    }

    public static func openURL(for handoff: ExtensionHandoff, downloadRoot: URL) throws -> URL {
        if handoff.kind == .torrentFile || handoff.kind == .metalinkFile {
            throw EngineError.handoffRejected("host")
        }
        var items = [URLQueryItem(name: "url", value: handoff.uri)]
        if let outputName = handoff.outputName {
            items.append(URLQueryItem(name: "filename", value: outputName))
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = handoff.kind == .video ? videoHost : host
        components.queryItems = items
        guard let url = components.url, url.absoluteString.count <= 8192 else {
            throw EngineError.handoffRejected("length")
        }
        let again = try stage(openURL: url, downloadRoot: downloadRoot)
        guard again.uri == handoff.uri, again.outputName == handoff.outputName, again.kind == handoff.kind
        else {
            throw EngineError.handoffRejected("message")
        }
        return url
    }

    private static func make(
        urlText: String,
        filename: String?,
        downloadRoot: URL,
        kind: ExtensionHandoffKind
    ) throws -> ExtensionHandoff {
        if kind == .torrentFile || kind == .metalinkFile {
            throw EngineError.handoffRejected("type")
        }
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw EngineError.schemeRejected("empty")
        }
        if trimmed.hasPrefix("-") {
            throw EngineError.schemeRejected("option")
        }
        if trimmed.count > 4096 {
            throw EngineError.handoffRejected("length")
        }
        if trimmed.contains(where: \.isWhitespace) {
            throw EngineError.schemeRejected("whitespace")
        }
        guard let parsed = URL(string: trimmed), parsed.scheme != nil else {
            throw EngineError.schemeRejected("unparseable")
        }
        let accepted = try acceptedURI(parsed, kind: kind)
        let outputName = try acceptedName(filename)
        var options: [String: String] = [:]
        if let outputName {
            options["out"] = outputName
        }
        if options.keys.contains(where: { $0 != "out" }) {
            throw EngineError.handoffRejected("options")
        }
        try RPCOptionPolicy.validate(options, downloadRoot: downloadRoot)
        return ExtensionHandoff(
            uri: accepted.uri,
            outputName: outputName,
            url: accepted.url,
            kind: kind
        )
    }

    private static func acceptedURI(
        _ url: URL,
        kind: ExtensionHandoffKind
    ) throws -> (uri: String, url: URL) {
        let absolute = url.absoluteString
        if absolute.hasPrefix("-") {
            throw EngineError.schemeRejected("option")
        }
        switch url.scheme?.lowercased() {
        case "http", "https":
            if kind == .video {
                try HTTPURLPolicy.validate(url)
            } else {
                try HTTPURLPolicy.validateTransfer(url)
            }
            guard let canonical = URL(string: absolute) else {
                throw EngineError.schemeRejected("unparseable")
            }
            return (absolute, canonical)
        case "ftp", "sftp":
            if kind == .video {
                throw EngineError.schemeRejected(url.scheme?.lowercased() ?? "")
            }
            try HTTPURLPolicy.validateTransfer(url)
            guard let canonical = URL(string: absolute) else {
                throw EngineError.schemeRejected("unparseable")
            }
            return (absolute, canonical)
        case "magnet":
            if kind == .video {
                throw EngineError.schemeRejected("magnet")
            }
            let canonical = try MagnetLink.canonical(url)
            guard let magnet = URL(string: canonical) else {
                throw EngineError.magnetRejected("scheme")
            }
            return (canonical, magnet)
        case let scheme?:
            throw EngineError.schemeRejected(scheme)
        case nil:
            throw EngineError.schemeRejected("")
        }
    }

    private static func acceptedName(_ filename: String?) throws -> String? {
        guard let filename else {
            return nil
        }
        let name = filename.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            return nil
        }
        if name.hasPrefix("-") {
            throw EngineError.outputNameRejected(name)
        }
        if name.count > 255 {
            throw EngineError.outputNameRejected(name)
        }
        try DownloadPath.validateOutputName(name)
        return name
    }

    private static func validateMetalinkFile(_ url: URL) throws {
        var info = stat()
        if stat(url.path, &info) != 0 {
            throw EngineError.handoffRejected("unreadable")
        }
        if (info.st_mode & S_IFMT) != S_IFREG {
            throw EngineError.handoffRejected("type")
        }
        if info.st_size <= 0 || info.st_size > 1_048_576 {
            throw EngineError.handoffRejected("size")
        }
    }

    private static func fields(from message: Any) throws -> (url: String, filename: String?, video: Bool) {
        let object = try dictionary(message)
        for key in object.keys where !messageKeys.contains(key) {
            throw EngineError.handoffRejected(key)
        }
        guard let urlValue = object["url"] else {
            throw EngineError.schemeRejected("empty")
        }
        let url = try stringValue(urlValue, key: "url")
        let filename: String?
        if let filenameValue = object["filename"] {
            filename = try stringValue(filenameValue, key: "filename")
        } else {
            filename = nil
        }
        let video: Bool
        if let videoValue = object["video"] {
            video = try trueFlag(videoValue, key: "video")
        } else {
            video = false
        }
        return (url, filename, video)
    }

    private static func dictionary(_ message: Any) throws -> [String: Any] {
        if let object = message as? [String: Any] {
            return object
        }
        if let object = message as? [String: String] {
            var copy: [String: Any] = [:]
            for (key, value) in object {
                copy[key] = value
            }
            return copy
        }
        throw EngineError.handoffRejected("message")
    }

    private static func stringValue(_ value: Any, key: String) throws -> String {
        guard let text = value as? String else {
            throw EngineError.handoffRejected(key)
        }
        return text
    }

    private static func trueFlag(_ value: Any, key: String) throws -> Bool {
        if let flag = value as? Bool {
            guard flag else {
                throw EngineError.handoffRejected(key)
            }
            return true
        }
        if let number = value as? NSNumber {
            let type = String(cString: number.objCType)
            if type == "c" || type == "B" || type == "C" {
                guard number.boolValue else {
                    throw EngineError.handoffRejected(key)
                }
                return true
            }
        }
        throw EngineError.handoffRejected(key)
    }

    private static func fields(from openURL: URL) throws -> (url: String, filename: String?, video: Bool) {
        let raw = openURL.absoluteString
        if raw.count > 8192 || raw.contains("\n") || raw.contains("\r") || raw.contains("\0") {
            throw EngineError.handoffRejected("length")
        }
        guard openURL.scheme?.lowercased() == scheme else {
            throw EngineError.schemeRejected(openURL.scheme?.lowercased() ?? "")
        }
        if openURL.user != nil || openURL.password != nil {
            throw EngineError.handoffRejected("userinfo")
        }
        let hostName = openURL.host?.lowercased() ?? ""
        let video: Bool
        switch hostName {
        case host:
            video = false
        case videoHost:
            video = true
        default:
            throw EngineError.handoffRejected("host")
        }
        if !openURL.path.isEmpty && openURL.path != "/" {
            throw EngineError.handoffRejected("path")
        }
        guard let components = URLComponents(url: openURL, resolvingAgainstBaseURL: false) else {
            throw EngineError.handoffRejected("message")
        }
        if components.fragment != nil {
            throw EngineError.handoffRejected("fragment")
        }
        let items = try queryItems(components)
        var urlText: String?
        var filename: String?
        var seen: Set<String> = []
        for item in items {
            if seen.contains(item.name) || !queryKeys.contains(item.name) {
                throw EngineError.handoffRejected(item.name)
            }
            seen.insert(item.name)
            guard let value = item.value else {
                throw EngineError.handoffRejected(item.name)
            }
            switch item.name {
            case "url":
                urlText = value
            case "filename":
                filename = value
            default:
                throw EngineError.handoffRejected(item.name)
            }
        }
        guard let urlText else {
            throw EngineError.schemeRejected("empty")
        }
        return (urlText, filename, video)
    }

    private static func queryItems(_ components: URLComponents) throws -> [URLQueryItem] {
        if components.percentEncodedQuery == nil {
            return []
        }
        guard let items = components.queryItems else {
            throw EngineError.handoffRejected("message")
        }
        return items
    }
}
