// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalEngine

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class VideoDownloadJobTests: XCTestCase {
    func testFakeHelperReceivesFixedArgumentsAndAScrubbedEnvironment() throws {
        let root = try makeJobRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try writeHelper(successScript, in: root)
        let watch = try TestBins.watchHelper()
        setenv("UMBLICAL_SENTINEL", "secret", 1)
        defer { unsetenv("UMBLICAL_SENTINEL") }
        let quarantine = RecordingQuarantine()
        let job = try VideoDownloadJob.start(
            ytDlp: helper,
            watch: watch,
            urlText: "https://example.com/watch?v=1",
            outputName: "clip.mp4",
            directory: nil,
            root: root,
            quarantine: quarantine
        )
        let progress = waitProgress(job, timeout: 8) { $0.phase != .running }
        XCTAssertEqual(progress.phase, .finished, progress.message ?? "")
        XCTAssertEqual(progress.completed, 50)
        XCTAssertEqual(progress.total, 100)
        let file = try XCTUnwrap(progress.filePath)
        XCTAssertEqual(URL(fileURLWithPath: file).lastPathComponent, "clip.mp4")
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), Data("payload".utf8))
        let resolved = try DownloadPath.resolveInside(root: root, raw: file)
        XCTAssertEqual(resolved, file)
        XCTAssertEqual(quarantine.paths.count, 1)
        XCTAssertTrue(quarantine.paths[0].hasPrefix(root.path))
        let escaped = root.appendingPathComponent("escaped.bin")
        XCTAssertEqual(try Data(contentsOf: escaped), Data("nope".utf8))
        XCTAssertFalse(quarantine.paths.contains(escaped.path))
        let argv = try String(contentsOf: root.appendingPathComponent("argv.txt"), encoding: .utf8)
        XCTAssertTrue(argv.contains("--ignore-config"))
        XCTAssertTrue(argv.contains("--no-config-locations"))
        XCTAssertTrue(argv.contains("--no-update"))
        XCTAssertTrue(argv.contains("https://example.com/watch?v=1"))
        XCTAssertFalse(argv.split(separator: "\n").contains("--exec"))
        XCTAssertFalse(argv.contains("--cookies"))
        XCTAssertFalse(argv.contains("-U"))
        let env = try String(contentsOf: root.appendingPathComponent("child.env"), encoding: .utf8)
        XCTAssertFalse(env.contains("UMBLICAL_SENTINEL"))
        XCTAssertTrue(env.contains("HOME=\(root.path)"))
    }

    func testCancelKillsTheHelper() throws {
        let root = try makeJobRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let helper = try writeHelper(cancelScript, in: root)
        let watch = try TestBins.watchHelper()
        let job = try VideoDownloadJob.start(
            ytDlp: helper,
            watch: watch,
            urlText: "https://example.com/watch?v=2",
            outputName: "",
            directory: nil,
            root: root,
            quarantine: RecordingQuarantine()
        )
        let pid = try waitPID(root.appendingPathComponent("helper.pid").path)
        let running = waitProgress(job, timeout: 5) { $0.completed == 50 && $0.phase == .running }
        XCTAssertEqual(running.completed, 50)
        XCTAssertTrue(running.phase == .running)
        job.cancel()
        let done = waitProgress(job, timeout: 5) { $0.phase != .running }
        XCTAssertEqual(done.phase, .cancelled)
        XCTAssertNotEqual(kill(pid, 0), 0)
    }

    func testMissingHelperDoesNotCreateAStagingDirectory() throws {
        let root = try makeJobRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let watch = try TestBins.watchHelper()
        XCTAssertThrowsError(
            try VideoDownloadJob.start(
                ytDlp: root.appendingPathComponent("missing-yt-dlp"),
                watch: watch,
                urlText: "https://example.com/a",
                outputName: "",
                directory: nil,
                root: root,
                quarantine: RecordingQuarantine()
            )
        ) { error in
            guard case EngineError.executableMissing("yt-dlp") = error else {
                return XCTFail("\(error)")
            }
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertFalse(names.contains { $0.hasPrefix("umb-video-") })
    }

    private func waitPID(_ path: String) throws -> Int32 {
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

    private func waitProgress(
        _ job: VideoDownloadJob,
        timeout: TimeInterval,
        until ready: (VideoDownloadProgress) -> Bool
    ) -> VideoDownloadProgress {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = job.progress()
        while Date() < deadline {
            latest = job.progress()
            if ready(latest) {
                return latest
            }
            usleep(50_000)
        }
        return latest
    }
}

private func makeJobRoot() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "umb-job-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeHelper(_ body: String, in directory: URL) throws -> URL {
    let url = directory.appendingPathComponent("yt-dlp-\(UUID().uuidString)")
    try Data(body.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url
}

private let successScript = """
    #!/bin/sh
    set -eu
    snapshot=$(mktemp)
    printf '%s\\n' "$@" > "$snapshot"
    env > "${snapshot}.env"
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
    if [ -z "$home" ]; then
      echo "missing home" >&2
      exit 2
    fi
    parent=$(dirname "$home")
    cp "$snapshot" "$parent/argv.txt"
    cp "${snapshot}.env" "$parent/child.env"
    rm -f "$snapshot" "${snapshot}.env"
    printf 'nope' > "$parent/escaped.bin"
    printf 'UMBPROGRESS 50 100 NA 10 5\\n' >&2
    printf 'payload' > "$home/umb-video.mp4"
    exit 0
    """

private let cancelScript = """
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
