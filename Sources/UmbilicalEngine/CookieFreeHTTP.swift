// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HTTP GET with no cookies, no stored credentials, and no extra auth headers.
enum CookieFreeHTTP {
    static let torrentByteLimit = 1_048_576

    static func get(_ url: URL, maxBytes: Int = torrentByteLimit) async throws -> Data {
        try HTTPURLPolicy.validate(url)
        if maxBytes <= 0 {
            throw EngineError.torrentRejected("size")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let session = URLSession(configuration: configuration)
        defer {
            session.finishTasksAndInvalidate()
        }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse {
            if !(200...299).contains(http.statusCode) {
                throw EngineError.torrentRejected("fetch")
            }
            if let length = contentLength(http), length > maxBytes {
                throw EngineError.torrentRejected("size")
            }
        }
        if data.isEmpty {
            throw EngineError.torrentRejected("fetch")
        }
        if data.count > maxBytes {
            throw EngineError.torrentRejected("size")
        }
        return data
    }

    private static func contentLength(_ response: HTTPURLResponse) -> Int? {
        if let value = response.value(forHTTPHeaderField: "Content-Length"), let length = Int(value)
        {
            return length
        }
        let length = response.expectedContentLength
        if length > 0 {
            return Int(length)
        }
        return nil
    }
}
