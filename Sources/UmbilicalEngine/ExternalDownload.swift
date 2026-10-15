// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A link staged from the Safari extension or an `umbilical://` open.
/// Staging does not start a download. `ExternalDownload.confirm` does that.
public struct ExtensionHandoff: Equatable {
    public let uri: String
    public let outputName: String?
    public let url: URL

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
}

public enum ExternalDownload {
    public static let scheme = "umbilical"
    public static let host = "download"
    /// Native messages and open-URL queries may carry only these fields.
    public static let messageKeys: Set<String> = ["url", "filename"]

    public static func stage(nativeMessage: Any, downloadRoot: URL) throws -> ExtensionHandoff {
        let parsed = try fields(from: nativeMessage)
        return try make(urlText: parsed.url, filename: parsed.filename, downloadRoot: downloadRoot)
    }

    public static func stage(openURL: URL, downloadRoot: URL) throws -> ExtensionHandoff {
        let parsed = try fields(from: openURL)
        return try make(urlText: parsed.url, filename: parsed.filename, downloadRoot: downloadRoot)
    }

    public static func stage(
        urlText: String,
        filename: String?,
        downloadRoot: URL
    ) throws -> ExtensionHandoff {
        try make(urlText: urlText, filename: filename, downloadRoot: downloadRoot)
    }

    public static func confirm(
        _ handoff: ExtensionHandoff,
        downloadRoot: URL
    ) throws -> ConfirmedExternalDownload {
        let staged = try stage(
            urlText: handoff.uri,
            filename: handoff.outputName,
            downloadRoot: downloadRoot
        )
        return ConfirmedExternalDownload(
            uri: staged.uri,
            outputName: staged.outputName,
            url: staged.url,
            options: staged.options
        )
    }

    public static func openURL(for handoff: ExtensionHandoff, downloadRoot: URL) throws -> URL {
        var items = [URLQueryItem(name: "url", value: handoff.uri)]
        if let outputName = handoff.outputName {
            items.append(URLQueryItem(name: "filename", value: outputName))
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = items
        guard let url = components.url, url.absoluteString.count <= 8192 else {
            throw EngineError.handoffRejected("length")
        }
        let again = try stage(openURL: url, downloadRoot: downloadRoot)
        guard again.uri == handoff.uri, again.outputName == handoff.outputName else {
            throw EngineError.handoffRejected("message")
        }
        return url
    }

    private static func make(
        urlText: String,
        filename: String?,
        downloadRoot: URL
    ) throws -> ExtensionHandoff {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            throw EngineError.schemeRejected("empty")
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
        let accepted = try acceptedURI(parsed)
        let outputName = try acceptedName(filename)
        var options: [String: String] = [:]
        if let outputName {
            options["out"] = outputName
        }
        if options.keys.contains(where: { $0 != "out" }) {
            throw EngineError.handoffRejected("options")
        }
        try RPCOptionPolicy.validate(options, downloadRoot: downloadRoot)
        return ExtensionHandoff(uri: accepted.uri, outputName: outputName, url: accepted.url)
    }

    private static func acceptedURI(_ url: URL) throws -> (uri: String, url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            try HTTPURLPolicy.validate(url)
            let absolute = url.absoluteString
            guard let canonical = URL(string: absolute) else {
                throw EngineError.schemeRejected("unparseable")
            }
            return (absolute, canonical)
        case "magnet":
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
        if name.count > 255 {
            throw EngineError.outputNameRejected(name)
        }
        try DownloadPath.validateOutputName(name)
        return name
    }

    private static func fields(from message: Any) throws -> (url: String, filename: String?) {
        let object = try dictionary(message)
        for key in object.keys where !messageKeys.contains(key) {
            throw EngineError.handoffRejected(key)
        }
        guard let urlValue = object["url"] else {
            throw EngineError.schemeRejected("empty")
        }
        let url = try stringValue(urlValue, key: "url")
        guard let filenameValue = object["filename"] else {
            return (url, nil)
        }
        return (url, try stringValue(filenameValue, key: "filename"))
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

    private static func fields(from openURL: URL) throws -> (url: String, filename: String?) {
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
        guard openURL.host?.lowercased() == host else {
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
            if seen.contains(item.name) || !messageKeys.contains(item.name) {
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
        return (urlText, filename)
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
