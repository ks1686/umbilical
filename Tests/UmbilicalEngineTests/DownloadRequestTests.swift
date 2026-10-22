// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalEngine

final class DownloadRequestTests: XCTestCase {
    func testPrepareAcceptsHTTPAndHTTPSInsideTheRoot() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try DownloadFolderRules.acceptRoot(root)
        let child = accepted.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let prepared = try DownloadRequests.prepare(
            urlText: " HTTPS://example.com/file.bin ",
            outputName: "file.bin",
            directory: child,
            root: accepted
        )
        XCTAssertEqual(prepared.url.scheme?.lowercased(), "https")
        XCTAssertEqual(prepared.options["out"], "file.bin")
        let dir = try XCTUnwrap(prepared.options["dir"])
        XCTAssertNoThrow(try DownloadFolderRules.resolveInside(root: accepted, raw: dir))
        let atRoot = try DownloadRequests.prepare(
            urlText: "http://example.com/a",
            outputName: "   ",
            directory: accepted,
            root: accepted
        )
        XCTAssertTrue(atRoot.options.isEmpty)
    }

    func testPrepareRejectsBadURLsAndNames() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let accepted = try DownloadFolderRules.acceptRoot(root)
        XCTAssertThrowsError(
            try DownloadRequests.prepare(
                urlText: "magnet:?xt=urn:btih:abcd",
                outputName: "",
                directory: nil,
                root: accepted
            )
        )
        XCTAssertThrowsError(
            try DownloadRequests.prepare(
                urlText: "--header=Bearer",
                outputName: "",
                directory: nil,
                root: accepted
            )
        )
        XCTAssertThrowsError(
            try DownloadRequests.prepare(
                urlText: "ftp://example.com/a.bin",
                outputName: "",
                directory: nil,
                root: accepted
            )
        )
        XCTAssertThrowsError(
            try DownloadRequests.prepare(
                urlText: "https://user:pw@example.com/a",
                outputName: "",
                directory: nil,
                root: accepted
            )
        )
        XCTAssertThrowsError(
            try DownloadRequests.prepare(
                urlText: "https://example.com/a",
                outputName: "../x",
                directory: nil,
                root: accepted
            )
        )
    }

    func testPrepareRejectsEscapesOutsideTheRoot() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("downloads", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let accepted = try DownloadFolderRules.acceptRoot(root)
        XCTAssertThrowsError(try DownloadFolderRules.acceptChild(outside, root: accepted))
        XCTAssertThrowsError(try DownloadFolderRules.acceptChild(link, root: accepted))
        XCTAssertThrowsError(
            try DownloadFolderRules.acceptRoot(root.appendingPathComponent("missing"))
        )
        let file = accepted.appendingPathComponent("note.txt")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try DownloadFolderRules.acceptRoot(file))
    }
}
