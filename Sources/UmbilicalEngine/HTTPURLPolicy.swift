// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum HTTPURLPolicy {
    static let pageSchemes: Set<String> = ["http", "https"]
    static let transferSchemes: Set<String> = ["http", "https", "ftp", "sftp"]

    static func validate(_ url: URL) throws {
        try validate(url, allowed: pageSchemes)
    }

    static func validateTransfer(_ url: URL) throws {
        try validate(url, allowed: transferSchemes)
    }

    private static func validate(_ url: URL, allowed: Set<String>) throws {
        guard let scheme = url.scheme?.lowercased() else {
            throw EngineError.schemeRejected("")
        }
        guard allowed.contains(scheme) else {
            throw EngineError.schemeRejected(scheme)
        }
        if url.user != nil || url.password != nil {
            throw EngineError.schemeRejected("userinfo")
        }
        guard let host = url.host, !host.isEmpty else {
            throw EngineError.schemeRejected(scheme)
        }
        let absolute = url.absoluteString
        if absolute.hasPrefix("-") {
            throw EngineError.schemeRejected("option")
        }
        if absolute.contains("\n") || absolute.contains("\r") || absolute.contains("\0") {
            throw EngineError.schemeRejected(scheme)
        }
    }
}
