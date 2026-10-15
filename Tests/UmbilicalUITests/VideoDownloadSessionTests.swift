// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalEngine
@testable import UmbilicalUI

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

@MainActor
final class VideoDownloadSessionTests: XCTestCase {
    func testMissingYtDlpDoesNotStartAria2() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = makeSession(video: VideoHelpers(ytDlp: nil, watch: nil))
        try await fixture.model.updateDownloadDirectory(root)
        do {
            try await fixture.model.addVideo(
                urlText: "https://example.com/a.mp4",
                outputName: "",
                folder: nil
            )
            XCTFail("expected missing yt-dlp")
        } catch let error as EngineError {
            guard case .executableMissing("yt-dlp") = error else {
                return XCTFail("\(error)")
            }
        }
        XCTAssertTrue(fixture.model.snapshot.rows.isEmpty)
        XCTAssertTrue(fixture.client.added.isEmpty)
    }

    func testVideoRowShowsProgressThenCompletes() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try writeVideoHelper(quickVideoScript, in: root)
        let quarantine = SessionQuarantine()
        let fixture = try await runningVideoSession(
            root: root,
            helper: helper,
            quarantine: quarantine
        )
        try await fixture.model.addVideo(
            urlText: "https://example.com/watch?v=1",
            outputName: "clip.mp4",
            folder: nil
        )
        let row = try await waitRow(fixture.model, timeout: 8) { $0.isComplete }
        XCTAssertEqual(row.title, "clip.mp4")
        XCTAssertFalse(row.canPause)
        XCTAssertFalse(row.cancelsLiveVideo)
        let file = try XCTUnwrap(row.filePath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), Data("payload".utf8))
        XCTAssertEqual(try DownloadPath.resolveInside(root: root, raw: file), file)
        XCTAssertEqual(quarantine.paths.count, 1)
        XCTAssertTrue(quarantine.paths[0].hasPrefix(root.path))
        XCTAssertTrue(fixture.client.added.isEmpty)
    }

    func testCancelRemovesTheRowAndKillsTheHelper() async throws {
        let root = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try writeVideoHelper(cancelVideoScript, in: root)
        let fixture = try await runningVideoSession(
            root: root,
            helper: helper,
            quarantine: SessionQuarantine()
        )
        try await fixture.model.addVideo(
            urlText: "https://example.com/watch?v=2",
            outputName: "",
            folder: nil
        )
        let pid = try waitHelperPID(root.appendingPathComponent("helper.pid").path)
        let running = try await waitRow(fixture.model, timeout: 5) { row in
            row.isActive && row.fraction != nil
        }
        XCTAssertTrue(running.cancelsLiveVideo)
        XCTAssertFalse(running.canPause)
        await fixture.model.remove(id: running.id)
        XCTAssertTrue(fixture.model.snapshot.rows.isEmpty)
        XCTAssertNotEqual(kill(pid, 0), 0)
        XCTAssertTrue(fixture.client.added.isEmpty)
    }

    func testKnownHostToggleYieldsToTheUser() {
        XCTAssertTrue(
            VideoToggleState.resolved(
                urlText: "https://youtu.be/abcdefghijk",
                userDidChoose: false,
                current: false
            )
        )
        XCTAssertFalse(
            VideoToggleState.resolved(
                urlText: "https://www.youtube.com/watch?v=1",
                userDidChoose: true,
                current: false
            )
        )
        XCTAssertTrue(
            VideoToggleState.resolved(
                urlText: "https://example.com/a.mp4",
                userDidChoose: true,
                current: true
            )
        )
    }
}

@MainActor
private func runningVideoSession(
    root: URL,
    helper: URL,
    quarantine: SessionQuarantine
) async throws -> SessionFixture {
    let fixture = makeSession(
        video: VideoHelpers(ytDlp: helper, watch: try watchBinary()),
        quarantine: quarantine
    )
    try await fixture.model.updateDownloadDirectory(root)
    return fixture
}

@MainActor
private func waitRow(
    _ model: DownloadSessionModel,
    timeout: TimeInterval,
    until ready: (DownloadRow) -> Bool
) async throws -> DownloadRow {
    let deadline = Date().addingTimeInterval(timeout)
    var latest: DownloadRow?
    while Date() < deadline {
        await model.refresh()
        latest = model.snapshot.rows.first
        if let latest, ready(latest) {
            return latest
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    XCTFail("video row did not reach the expected state")
    return try XCTUnwrap(latest)
}

private func waitHelperPID(_ path: String) throws -> Int32 {
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline {
        if let pid = helperPID(at: path) {
            return pid
        }
        usleep(50_000)
    }
    XCTFail("helper pid was not written")
    return -1
}

private func helperPID(at path: String) -> Int32? {
    guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
        return nil
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let pid = Int32(trimmed), pid > 1 else {
        return nil
    }
    return pid
}

private func writeVideoHelper(_ body: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("yt-dlp-\(UUID().uuidString)")
    try Data(body.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private func watchBinary() throws -> URL {
    let source = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Sources/umb-watch/main.c")
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent("umb-watch-\(UUID().uuidString)")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
    process.arguments = ["-D_GNU_SOURCE", "-O2", "-o", output.path, source.path]
    try process.run()
    process.waitUntilExit()
    let compiled = FileManager.default.isExecutableFile(atPath: output.path)
    if process.terminationStatus != 0 || !compiled {
        throw VideoFixtureError.watchCompileFailed
    }
    return output
}

private enum VideoFixtureError: Error {
    case watchCompileFailed
}

private final class SessionQuarantine: QuarantineApplying {
    private let lock = NSLock()
    private var recorded: [String] = []

    func markDownloaded(file: URL) throws {
        lock.lock()
        recorded.append(file.path)
        lock.unlock()
    }

    var paths: [String] {
        lock.lock()
        let copy = recorded
        lock.unlock()
        return copy
    }
}

private let quickVideoScript = """
    #!/bin/sh
    set -eu
    home=""
    while [ "$#" -gt 0 ]; do
      arg="$1"
      shift
      if [ "$arg" = "--paths" ] && [ "$#" -gt 0 ]; then
        value="$1"
        shift
        case "$value" in
          home:*)
            home=${value#home:}
            ;;
        esac
      fi
    done
    test -n "$home"
    printf 'UMBPROGRESS 40 80 NA 12 3\\n' >&2
    printf 'payload' > "$home/umb-video.mp4"
    """

private let cancelVideoScript = """
    #!/bin/sh
    set -eu
    home=""
    while [ "$#" -gt 0 ]; do
      arg="$1"
      shift
      if [ "$arg" = "--paths" ] && [ "$#" -gt 0 ]; then
        value="$1"
        shift
        case "$value" in
          home:*)
            home=${value#home:}
            ;;
        esac
      fi
    done
    parent=$(dirname "$home")
    printf '%s\\n' "$$" > "$parent/helper.pid"
    printf 'UMBPROGRESS 50 200 NA 8 4\\n' >&2
    sleep 60
    """
