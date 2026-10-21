// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

@testable import UmbilicalEngine

final class CookieFreeHostTests: XCTestCase {
    func testLoopbackLinkLocalAndPrivateIPv4AreBlocked() throws {
        let blocked = [
            "http://127.0.0.1/a.torrent",
            "http://127.255.255.255/a.torrent",
            "http://0.0.0.0/a.torrent",
            "http://10.0.0.1/a.torrent",
            "http://172.16.0.1/a.torrent",
            "http://172.31.255.255/a.torrent",
            "http://192.168.1.1/a.torrent",
            "http://169.254.1.1/a.torrent",
            "http://localhost/a.torrent",
            "http://LOCALHOST./a.torrent"
        ]
        for text in blocked {
            try assertHostRejected(text)
        }
    }

    func testLoopbackLinkLocalAndPrivateIPv6AreBlocked() throws {
        let blocked = [
            "http://[::1]/a.torrent",
            "http://[::]/a.torrent",
            "http://[fe80::1]/a.torrent",
            "http://[fc00::1]/a.torrent",
            "http://[fd12:3456::1]/a.torrent",
            "http://[::ffff:127.0.0.1]/a.torrent",
            "http://[::ffff:10.1.2.3]/a.torrent",
            "http://[::ffff:192.168.0.9]/a.torrent"
        ]
        for text in blocked {
            try assertHostRejected(text)
        }
    }

    func testPublicAddressesAndHTTPSAreAllowed() throws {
        try CookieFreeHost.validate(try testURL("https://1.1.1.1/a.torrent"))
        try CookieFreeHost.validate(try testURL("http://8.8.8.8/a.torrent"))
        try CookieFreeHost.validate(try testURL("http://172.32.0.1/a.torrent"))
        try CookieFreeHost.validate(
            try testURL("http://[2001:4860:4860::8888]/a.torrent")
        )
    }

    func testRedirectsCapAndStayOnHTTP() throws {
        let allowed = try testURL("https://1.1.1.1/a.torrent")
        try CookieFreeHost.acceptedHop(allowed, hops: CookieFreeHost.maxRedirects)
        try assertHopRejected(allowed, hops: CookieFreeHost.maxRedirects + 1, detail: "fetch")
        try assertHopRejected(nil, hops: 1, detail: "fetch")
        try assertHopRejected(
            try testURL("ftp://1.1.1.1/a.torrent"),
            hops: 1,
            detail: "ftp"
        )
        try assertHopRejected(
            try testURL("http://192.168.0.1/a.torrent"),
            hops: 1,
            detail: "host"
        )
        try assertHopRejected(
            try testURL("https://127.0.0.1/a.torrent"),
            hops: 1,
            detail: "host"
        )
    }

    private func assertHostRejected(_ text: String) throws {
        let url = try testURL(text)
        XCTAssertThrowsError(try CookieFreeHost.validate(url), text) { error in
            XCTAssertEqual(error as? EngineError, .torrentRejected("host"), text)
        }
    }

    private func assertHopRejected(_ url: URL?, hops: Int, detail: String) throws {
        XCTAssertThrowsError(try CookieFreeHost.acceptedHop(url, hops: hops)) { error in
            if detail == "ftp" {
                XCTAssertEqual(error as? EngineError, .schemeRejected("ftp"))
            } else {
                XCTAssertEqual(error as? EngineError, .torrentRejected(detail))
            }
        }
    }
}

final class CookieFreeHTTPPolicyTests: XCTestCase {
    func testGetRejectsLoopbackBeforeConnecting() async throws {
        let url = try testURL("http://127.0.0.1:9/payload.torrent")
        do {
            _ = try await CookieFreeHTTP.get(url)
            XCTFail("expected loopback to be rejected")
        } catch let error as EngineError {
            XCTAssertEqual(error, .torrentRejected("host"))
        }
    }

    func testAcceptedBodyEnforcesTheSizeCap() throws {
        let url = try testURL("https://1.1.1.1/a.torrent")
        let ok = try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        )
        let body = Data([1, 2, 3, 4])
        XCTAssertEqual(try CookieFreeHTTP.acceptedBody(body, response: ok, maxBytes: 4), body)
        XCTAssertThrowsError(
            try CookieFreeHTTP.acceptedBody(body, response: ok, maxBytes: 3)
        ) { error in
            XCTAssertEqual(error as? EngineError, .torrentRejected("size"))
        }
        let long = try XCTUnwrap(
            HTTPURLResponse(
                url: url,
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Length": "8"]
            )
        )
        XCTAssertThrowsError(
            try CookieFreeHTTP.acceptedBody(body, response: long, maxBytes: 4)
        ) { error in
            XCTAssertEqual(error as? EngineError, .torrentRejected("size"))
        }
        let failed = try XCTUnwrap(
            HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: nil)
        )
        XCTAssertThrowsError(
            try CookieFreeHTTP.acceptedBody(body, response: failed, maxBytes: 16)
        ) { error in
            XCTAssertEqual(error as? EngineError, .torrentRejected("fetch"))
        }
    }
}
