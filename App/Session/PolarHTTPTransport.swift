// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public enum PolarTransportError: Error, Equatable {
    case rejectedURL
}

public final class PolarHTTPTransport: LicenseTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            self.session = Self.makeSession()
        }
    }

    public func send(_ call: PolarCall) async throws -> PolarReply {
        guard let request = PolarRequestBuilder.urlRequest(path: call.path, body: call.body) else {
            throw PolarTransportError.rejectedURL
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw PolarTransportError.rejectedURL
        }
        return PolarReply(statusCode: http.statusCode, body: data)
    }

    private static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(
            configuration: config,
            delegate: PolarRedirectBlock(),
            delegateQueue: nil
        )
    }
}

/// Refuses redirects so a license key cannot be sent to another host.
final class PolarRedirectBlock: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
