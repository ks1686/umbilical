// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalEngine

final class PartialFileCleanupTests: XCTestCase {
    func testContainedFileAndControlFileAreListed() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("partial.bin")
        try Data("data".utf8).write(to: file)
        try Data("ctrl".utf8).write(to: URL(fileURLWithPath: file.path + ".aria2"))
        let listed = PartialFileCleanup.deletablePaths(
            files: [file],
            downloadDirectory: root
        )
        XCTAssertEqual(Set(listed), [file.path, file.path + ".aria2"])
    }

    func testOutsideSymlinkIsRefused() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("downloads", isDirectory: true)
        let outside = parent.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let secret = outside.appendingPathComponent("secret.bin")
        try Data("secret".utf8).write(to: secret)
        let link = root.appendingPathComponent("escape.bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)
        let listed = PartialFileCleanup.deletablePaths(
            files: [link],
            downloadDirectory: root
        )
        XCTAssertTrue(listed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
        PartialFileCleanup.delete(files: [link], downloadDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testParentDirectoryPathIsRefused() throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let root = parent.appendingPathComponent("downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let secret = parent.appendingPathComponent("secret.bin")
        try Data("secret".utf8).write(to: secret)
        let escaped = root.appendingPathComponent("..").appendingPathComponent("secret.bin")
        XCTAssertThrowsError(try DownloadPath.deletableRegularFile(root: root, raw: escaped.path))
        XCTAssertThrowsError(
            try DownloadPath.deletableRegularFile(root: root, raw: "../secret.bin"))
        let listed = PartialFileCleanup.deletablePaths(
            files: [escaped],
            downloadDirectory: root
        )
        XCTAssertTrue(listed.isEmpty)
        PartialFileCleanup.delete(files: [escaped], downloadDirectory: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))
    }

    func testDirectoryIsRefused() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        XCTAssertThrowsError(try DownloadPath.deletableRegularFile(root: root, raw: nested.path))
        let listed = PartialFileCleanup.deletablePaths(
            files: [nested],
            downloadDirectory: root
        )
        XCTAssertTrue(listed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.path))
    }
}
