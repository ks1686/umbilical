// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalEngine

final class VideoDownloadFinisherTests: XCTestCase {
    func testAdoptMovesARegularFileAndQuarantinesIt() throws {
        let root = try makeVideoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try VideoDownloadPlan.makeStagingDirectory(in: root)
        try Data("payload".utf8).write(to: staging.appendingPathComponent("umb-video.mp4"))
        try Data("part".utf8).write(to: staging.appendingPathComponent("umb-video.mp4.part"))
        let quarantine = RecordingQuarantine()
        let file = try VideoDownloadFinisher.adopt(
            staging: staging,
            folder: root,
            root: root,
            outputName: "clip.mp4",
            quarantine: quarantine
        )
        XCTAssertEqual(file.lastPathComponent, "clip.mp4")
        XCTAssertEqual(try Data(contentsOf: file), Data("payload".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
        XCTAssertEqual(quarantine.paths.count, 1)
        XCTAssertTrue(quarantine.paths[0].hasSuffix("/umb-video.mp4"))
        let resolved = try DownloadPath.resolveInside(root: root, raw: file.path)
        XCTAssertEqual(resolved, file.path)
    }

    func testDefaultNameStaysInsideTheFolder() throws {
        let root = try makeVideoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let staging = try VideoDownloadPlan.makeStagingDirectory(in: nested)
        try Data("payload".utf8).write(
            to: staging.appendingPathComponent("Cute_Cat_Video [abc123].webm")
        )
        let file = try VideoDownloadFinisher.adopt(
            staging: staging,
            folder: nested,
            root: root,
            outputName: nil,
            quarantine: RecordingQuarantine()
        )
        XCTAssertEqual(file.lastPathComponent, "Cute_Cat_Video [abc123].webm")
        XCTAssertEqual(file.deletingLastPathComponent().path, nested.path)
        let resolved = try DownloadPath.resolveInside(root: root, raw: file.path)
        XCTAssertEqual(resolved, file.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    }

    func testAdoptedTitleStripsALeadingDashAndCapsLength() throws {
        let root = try makeVideoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let dashStaging = try VideoDownloadPlan.makeStagingDirectory(in: root)
        try Data("dash".utf8).write(to: dashStaging.appendingPathComponent("-evil.mp4"))
        let dashed = try VideoDownloadFinisher.adopt(
            staging: dashStaging,
            folder: root,
            root: root,
            outputName: nil,
            quarantine: RecordingQuarantine()
        )
        XCTAssertEqual(dashed.lastPathComponent, "evil.mp4")
        XCTAssertEqual(try DownloadPath.resolveInside(root: root, raw: dashed.path), dashed.path)

        let longStaging = try VideoDownloadPlan.makeStagingDirectory(in: root)
        let longName = String(repeating: "A", count: 200) + " [id].mp4"
        try Data("long".utf8).write(to: longStaging.appendingPathComponent(longName))
        let capped = try VideoDownloadFinisher.adopt(
            staging: longStaging,
            folder: root,
            root: root,
            outputName: nil,
            quarantine: RecordingQuarantine()
        )
        XCTAssertLessThanOrEqual(
            capped.lastPathComponent.count, VideoDownloadPlan.maxFileNameLength)
        XCTAssertTrue(capped.lastPathComponent.hasSuffix(".mp4"))
        XCTAssertEqual(capped.deletingLastPathComponent().path, root.path)
        XCTAssertEqual(try DownloadPath.resolveInside(root: root, raw: capped.path), capped.path)
    }

    func testSymlinkAndExistingNamesAreRejected() throws {
        let root = try makeVideoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try makeVideoRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
        let secret = outside.appendingPathComponent("secret.bin")
        try Data("secret".utf8).write(to: secret)
        let staging = try VideoDownloadPlan.makeStagingDirectory(in: root)
        try FileManager.default.createSymbolicLink(
            at: staging.appendingPathComponent("umb-video.mp4"),
            withDestinationURL: secret
        )
        let quarantine = RecordingQuarantine()
        XCTAssertThrowsError(
            try VideoDownloadFinisher.adopt(
                staging: staging,
                folder: root,
                root: root,
                outputName: nil,
                quarantine: quarantine
            )
        )
        XCTAssertTrue(quarantine.paths.isEmpty)
        XCTAssertEqual(try Data(contentsOf: secret), Data("secret".utf8))

        let again = try VideoDownloadPlan.makeStagingDirectory(in: root)
        try Data("new".utf8).write(to: again.appendingPathComponent("umb-video.mp4"))
        let existing = root.appendingPathComponent("clip.mp4")
        try Data("keep".utf8).write(to: existing)
        XCTAssertThrowsError(
            try VideoDownloadFinisher.adopt(
                staging: again,
                folder: root,
                root: root,
                outputName: "clip.mp4",
                quarantine: quarantine
            )
        )
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8))
        XCTAssertTrue(quarantine.paths.isEmpty)
    }
}
