// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalEngine

final class VideoPagePolicyTests: XCTestCase {
    func testKnownHostsPreferVideo() {
        XCTAssertTrue(
            VideoPagePolicy.prefersVideo(urlText: " https://www.YouTube.com/watch?v=abcdefghijk ")
        )
        XCTAssertTrue(VideoPagePolicy.prefersVideo(urlText: "https://youtu.be/abcdefghijk"))
        XCTAssertTrue(VideoPagePolicy.prefersVideo(urlText: "https://m.youtube.com/watch?v=1"))
        XCTAssertTrue(VideoPagePolicy.prefersVideo(urlText: "https://vimeo.com/1"))
        XCTAssertFalse(VideoPagePolicy.prefersVideo(urlText: "https://notyoutube.com/watch?v=1"))
        XCTAssertFalse(VideoPagePolicy.prefersVideo(urlText: "https://youtube.com.evil.test/a"))
        XCTAssertFalse(VideoPagePolicy.prefersVideo(urlText: "https://example.com/video.mp4"))
        XCTAssertFalse(
            VideoPagePolicy.prefersVideo(urlText: "https://user:secret@youtube.com/watch?v=1")
        )
        XCTAssertFalse(VideoPagePolicy.prefersVideo(urlText: "file:///tmp/x"))
    }
}

final class VideoDownloadPlanTests: XCTestCase {
    func testArgumentsAreFixedAndConfined() throws {
        let root = try makeVideoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try VideoDownloadPlan.makeStagingDirectory(in: root)
        let target = try VideoDownloadPlan.target(
            urlText: " https://example.com/watch?v=1 ",
            outputName: " clip.mp4 ",
            directory: nil,
            root: root
        )
        let arguments = try VideoDownloadPlan.arguments(for: target, stagingDirectory: staging)
        XCTAssertEqual(target.outputName, "clip.mp4")
        XCTAssertFalse(arguments.contains("clip.mp4"))
        XCTAssertFalse(arguments.contains("+"))
        XCTAssertFalse(VideoDownloadPlan.formatSelector.contains("+"))
        XCTAssertFalse(VideoDownloadPlan.formatSelector.contains(" "))
        XCTAssertTrue(VideoDownloadPlan.formatSelector.contains("acodec!=none"))
        XCTAssertTrue(VideoDownloadPlan.formatSelector.contains("vcodec!=none"))
        XCTAssertTrue(VideoDownloadPlan.formatSelector.contains("/"))
        XCTAssertFalse(VideoDownloadPlan.formatSelector.contains("bv*"))
        XCTAssertEqual(arguments.last, "https://example.com/watch?v=1")
        XCTAssertEqual(arguments[arguments.count - 2], "--")
        XCTAssertEqual(VideoDownloadPlan.outputTemplate, "%(title).150B [%(id)s].%(ext)s")
        assertRequired(arguments)
        XCTAssertEqual(pair("--downloader", in: arguments), "native")
        XCTAssertEqual(pair("--fixup", in: arguments), "never")
        XCTAssertEqual(pair("--format", in: arguments), VideoDownloadPlan.formatSelector)
        XCTAssertEqual(pair("--output", in: arguments), VideoDownloadPlan.outputTemplate)
        XCTAssertEqual(pair("--ffmpeg-location", in: arguments), staging.path)
        XCTAssertEqual(pair("--trim-filenames", in: arguments), VideoDownloadPlan.trimFilenames)
        XCTAssertTrue(arguments.contains("--restrict-filenames"))
        XCTAssertTrue(arguments.contains("--windows-filenames"))
        XCTAssertTrue(arguments.contains("home:\(staging.path)"))
        XCTAssertTrue(arguments.contains("temp:\(staging.path)"))
        XCTAssertFalse(arguments.contains { $0.hasPrefix("--cookies") })
        let resolved = try DownloadPath.resolveInside(root: root, raw: staging.path)
        XCTAssertEqual(resolved, staging.path)
    }

    func testCanonicalRootFollowsADirectorySymlink() throws {
        let root = try makeVideoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = try makeVideoRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let link = parent.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
        let leaf = link.appendingPathComponent("leaf", isDirectory: true)
        try FileManager.default.createDirectory(at: leaf, withIntermediateDirectories: true)
        let canonical = try canonicalDirectory(leaf)
        XCTAssertEqual(canonical.path, root.appendingPathComponent("leaf").path)
    }

    func testRejectedURLs() throws {
        let root = try makeVideoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let rejected = [
            "file:///tmp/x",
            "javascript:alert(1)",
            "https://user:secret@example.com/a",
            "",
            "https://example.com/a b",
            "-https://example.com/a",
            "--newline",
            "ftp://example.com/a.mp4"
        ]
        for text in rejected {
            XCTAssertThrowsError(
                try VideoDownloadPlan.target(
                    urlText: text,
                    outputName: "",
                    directory: nil,
                    root: root
                ),
                text
            )
        }
    }

    func testRejectedNamesAndDirectories() throws {
        let root = try makeVideoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(
            try VideoDownloadPlan.target(
                urlText: "https://example.com/a",
                outputName: "../x",
                directory: nil,
                root: root
            )
        ) { error in
            guard case EngineError.outputNameRejected = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertThrowsError(
            try VideoDownloadPlan.target(
                urlText: "https://example.com/a",
                outputName: "100%",
                directory: nil,
                root: root
            )
        ) { error in
            guard case EngineError.videoRejected = error else {
                return XCTFail("\(error)")
            }
        }
        let outside = try makeVideoRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
        XCTAssertThrowsError(
            try VideoDownloadPlan.target(
                urlText: "https://example.com/a",
                outputName: "",
                directory: outside,
                root: root
            )
        )
        try assertStagingOutsideRoot(root, outside: outside)
    }

    private func assertStagingOutsideRoot(_ root: URL, outside: URL) throws {
        let elsewhere = try VideoDownloadPlan.makeStagingDirectory(in: outside)
        let target = try VideoDownloadPlan.target(
            urlText: "https://example.com/a",
            outputName: "",
            directory: nil,
            root: root
        )
        XCTAssertThrowsError(
            try VideoDownloadPlan.arguments(for: target, stagingDirectory: elsewhere)
        )
    }

    func testFormatSelectorRequiresAudioAndVideo() {
        let selector = VideoDownloadPlan.formatSelector
        XCTAssertEqual(
            selector,
            "b[acodec!=none][vcodec!=none]/best[acodec!=none][vcodec!=none]"
        )
        XCTAssertFalse(selector.contains("+"))
        XCTAssertFalse(selector.contains("bv*"))
        XCTAssertFalse(selector.contains("/ba"))
    }

    func testMissingCombinedFormatMapsToAPlainError() {
        XCTAssertEqual(
            VideoDownloadPlan.failureMessage(from: [
                "ERROR: [youtube] abc: Requested format is not available. Use --list-formats"
            ]),
            VideoDownloadPlan.unavailableAudioMessage
        )
        let generic = VideoDownloadPlan.failureMessage(from: ["HTTP Error 403: Forbidden"])
        XCTAssertTrue(generic.hasPrefix("The video download failed."))
        XCTAssertTrue(generic.contains("403"))
        XCTAssertFalse(generic.contains("without extra tools"))
        XCTAssertEqual(VideoDownloadPlan.failureMessage(from: []), "The video download failed.")
    }

    func testURLIsPassedAfterADoubleDash() throws {
        let root = try makeVideoRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let staging = try VideoDownloadPlan.makeStagingDirectory(in: root)
        let target = try VideoDownloadPlan.target(
            urlText: "https://example.com/watch?v=1",
            outputName: "",
            directory: nil,
            root: root
        )
        let arguments = try VideoDownloadPlan.arguments(for: target, stagingDirectory: staging)
        XCTAssertGreaterThanOrEqual(arguments.count, 2)
        XCTAssertEqual(arguments[arguments.count - 2], "--")
        XCTAssertEqual(arguments.last, target.url.absoluteString)
        XCTAssertEqual(arguments.filter { $0 == target.url.absoluteString }.count, 1)
        XCTAssertFalse(
            arguments.dropLast().contains { $0.hasPrefix("-") && $0.contains("example") })
    }

    func testUntrustedTitlesCannotEscapeTheDownloadFolder() throws {
        XCTAssertThrowsError(try VideoDownloadPlan.sanitizedFileName("../secret.mp4")) { error in
            guard case EngineError.outputNameRejected = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertThrowsError(try VideoDownloadPlan.sanitizedFileName("..\\secret.mp4")) { error in
            guard case EngineError.outputNameRejected = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertEqual(try VideoDownloadPlan.sanitizedFileName("-evil.mp4"), "evil.mp4")
        XCTAssertEqual(
            try VideoDownloadPlan.sanitizedFileName("--.Dash_Title [id].webm"),
            "Dash_Title [id].webm")
        let longTitle = String(repeating: "A", count: 400) + " [id].mp4"
        let capped = try VideoDownloadPlan.sanitizedFileName(longTitle)
        XCTAssertLessThanOrEqual(capped.count, VideoDownloadPlan.maxFileNameLength)
        XCTAssertTrue(capped.hasSuffix(".mp4"))
        XCTAssertFalse(capped.hasPrefix("."))
        XCTAssertFalse(capped.hasPrefix("-"))
        let token = String(repeating: "ab", count: 16)
        XCTAssertNil(
            VideoDownloadPlan.finalFileName(
                outputName: nil,
                downloadedName: "../secret.mp4",
                ext: "mp4",
                token: token
            )
        )
        XCTAssertEqual(
            VideoDownloadPlan.finalFileName(
                outputName: nil,
                downloadedName: "-Cute_Cat [abc].mp4",
                ext: "mp4",
                token: token
            ),
            "Cute_Cat [abc].mp4"
        )
    }

    func testProgressParserReadsTheFixedTemplate() {
        let parsed = VideoProgressParser.parse("UMBPROGRESS 50 100 NA 10.5 5")
        XCTAssertEqual(parsed?.completed, 50)
        XCTAssertEqual(parsed?.total, 100)
        XCTAssertEqual(parsed?.speed, 10)
        let estimate = VideoProgressParser.parse("UMBPROGRESS 7 NA 80 NA NA")
        XCTAssertEqual(estimate?.completed, 7)
        XCTAssertEqual(estimate?.total, 80)
        XCTAssertEqual(estimate?.speed, 0)
        XCTAssertNil(VideoProgressParser.parse("download 1 2 3"))
        XCTAssertNil(VideoProgressParser.parse("UMBPROGRESS nope 1 2 3 4"))
    }

    private func assertRequired(_ arguments: [String]) {
        let required = [
            "--ignore-config",
            "--no-config-locations",
            "--no-plugin-dirs",
            "--no-update",
            "--no-remote-components",
            "--no-js-runtimes",
            "--no-playlist",
            "--no-cache-dir",
            "--no-exec",
            "--restrict-filenames",
            "--windows-filenames",
            "--trim-filenames",
            "--paths",
            "--"
        ]
        for flag in required {
            XCTAssertTrue(arguments.contains(flag), flag)
        }
        let forbidden = [
            "--exec",
            "--cookies",
            "--cookies-from-browser",
            "--config-locations",
            "--plugin-dirs",
            "--batch-file",
            "-U",
            "--update",
            "--update-to",
            "--downloader-args",
            "--external-downloader",
            "--js-runtimes",
            "--remote-components"
        ]
        for flag in forbidden {
            XCTAssertFalse(arguments.contains(flag), flag)
        }
    }

    private func pair(_ flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return arguments[index + 1]
    }
}

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

private func makeVideoRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "umb-video-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return try canonicalDirectory(url)
}

private func canonicalDirectory(_ url: URL) throws -> URL {
    // realpath. URL.resolvingSymlinksInPath left /var in place on macOS,
    // and /var is a symlink to /private/var.
    let resolved = try DownloadPath.resolveInside(root: url, raw: url.path)
    return URL(fileURLWithPath: resolved, isDirectory: true)
}
