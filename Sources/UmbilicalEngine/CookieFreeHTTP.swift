// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// HTTP GET with no cookies, no stored credentials, and no extra auth headers.
enum CookieFreeHTTP {
    static let torrentByteLimit = 1_048_576

    static func get(_ url: URL, maxBytes: Int = torrentByteLimit) async throws -> Data {
        try CookieFreeHost.validate(url)
        if maxBytes <= 0 {
            throw EngineError.torrentRejected("size")
        }
        let client = CookieFreeClient()
        let session = client.makeSession()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: url)
        } catch {
            session.invalidateAndCancel()
            throw error
        }
        session.invalidateAndCancel()
        if let blocked = client.hostError {
            throw blocked
        }
        return try acceptedBody(data, response: response, maxBytes: maxBytes)
    }

    static func acceptedBody(
        _ data: Data,
        response: URLResponse,
        maxBytes: Int
    ) throws -> Data {
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

private final class CookieFreeClient: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var hops = 0
    private(set) var hostError: EngineError?

    func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 20
        let queue = OperationQueue()
        queue.name = "umbilical.cookie-free-http"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let hop: Int
        lock.lock()
        hops += 1
        hop = hops
        lock.unlock()
        do {
            try CookieFreeHost.acceptedHop(request.url, hops: hop)
            completionHandler(request)
        } catch let error as EngineError {
            lock.lock()
            hostError = error
            lock.unlock()
            completionHandler(nil)
        } catch {
            completionHandler(nil)
        }
    }
}
