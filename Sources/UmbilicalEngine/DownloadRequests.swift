// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct PreparedDownload: Equatable {
    public let url: URL
    public let options: [String: String]

    public init(url: URL, options: [String: String]) {
        self.url = url
        self.options = options
    }
}

public enum DownloadRequests {
    public static func prepare(
        urlText: String,
        outputName: String,
        directory: URL?,
        root: URL
    ) throws -> PreparedDownload {
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.contains(where: \.isWhitespace) {
            throw EngineError.schemeRejected(trimmed.isEmpty ? "empty" : "whitespace")
        }
        if trimmed.hasPrefix("-") {
            throw EngineError.schemeRejected("option")
        }
        guard let url = URL(string: trimmed) else {
            throw EngineError.schemeRejected("unparseable")
        }
        try HTTPURLPolicy.validate(url)
        var options: [String: String] = [:]
        let name = outputName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            try DownloadPath.validateOutputName(name)
            options["out"] = name
        }
        if let directory {
            try addDirectory(directory, root: root, options: &options)
        }
        try RPCOptionPolicy.validate(options, downloadRoot: root)
        return PreparedDownload(url: url, options: options)
    }

    private static func addDirectory(
        _ directory: URL,
        root: URL,
        options: inout [String: String]
    ) throws {
        let resolved = try DownloadPath.resolveInside(root: root, raw: directory.path)
        let rootResolved = try DownloadPath.resolveInside(root: root, raw: root.path)
        if resolved != rootResolved {
            options["dir"] = resolved
        }
    }
}
