// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum HTTPURLPolicy {
    static func validate(_ url: URL) throws {
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
}
