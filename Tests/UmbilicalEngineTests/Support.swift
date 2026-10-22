// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalEngine

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

enum TestBins {
    static func watchHelper() throws -> URL {
        if let env = ProcessInfo.processInfo.environment["UMB_WATCH"], !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        let argv = URL(fileURLWithPath: CommandLine.arguments[0])
        var cursor = argv.deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = cursor.appendingPathComponent("umb-watch")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
            cursor.deleteLastPathComponent()
        }
        return try compileWatch()
    }

    static func aria2() -> URL? {
        let candidates = [
            ProcessInfo.processInfo.environment["ARIA2C"],
            "/tmp/aria2-install/bin/aria2c",
            "/usr/bin/aria2c"
        ]
        for candidate in candidates {
            guard let candidate, !candidate.isEmpty else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    static func requireAria2() throws -> URL {
        if let url = aria2() {
            return url
        }
        if ProcessInfo.processInfo.environment["UMB_REQUIRE_ARIA2"] == "1" {
            XCTFail("aria2c is required")
            throw FixtureError.missingAria2
        }
        throw XCTSkip("aria2c is not available")
    }

    private static func compileWatch() throws -> URL {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/umb-watch/main.c")
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("umb-watch-\(UUID().uuidString)")
        let compiler: String
        if FileManager.default.isExecutableFile(atPath: "/usr/bin/cc") {
            compiler = "/usr/bin/cc"
        } else {
            compiler = "/usr/bin/gcc"
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: compiler)
        process.arguments = ["-D_GNU_SOURCE", "-O2", "-o", output.path, source.path]
        try process.run()
        process.waitUntilExit()
        let compiled = FileManager.default.isExecutableFile(atPath: output.path)
        if process.terminationStatus != 0 || !compiled {
            throw FixtureError.watchCompileFailed
        }
        return output
    }
}

enum FixtureError: Error {
    case missingAria2
    case watchCompileFailed
    case timedOut
    case badFixture
}

struct TrialFailure: Error, CustomStringConvertible {
    var description: String
}

struct ImmediateProbe: RPCListening {
    func isListening(port: UInt16, secret: String) async -> Bool {
        _ = port
        _ = secret
        return true
    }
}

final class RecordingQuarantine: QuarantineApplying {
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

final class RecordingTransport: JSONRPCTransport {
    private let queue = DispatchQueue(label: "umb.test.transport")
    private var recorded: [String] = []
    private var recordedParameters: [[Any]] = []

    func call(method: String, parameters: [Any]) async throws -> Any {
        queue.sync {
            recorded.append(method)
            recordedParameters.append(parameters)
        }
        if method == "aria2.addMetalink" {
            return ["gid"]
        }
        if method == "aria2.getFiles" {
            return [] as [[String: Any]]
        }
        return "gid"
    }

    var methods: [String] {
        queue.sync { recorded }
    }

    var parameters: [[Any]] {
        queue.sync { recordedParameters }
    }
}

func testURL(_ string: String) throws -> URL {
    try XCTUnwrap(URL(string: string))
}

func waitForStatus(
    _ client: RPCClient,
    gid: String,
    timeout: TimeInterval,
    where predicate: (DownloadStatus) -> Bool
) async throws -> DownloadStatus {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let status = try await client.status(gid: gid)
        if status.state == .error {
            throw EngineError.unexpectedStatus(status.errorMessage ?? "error")
        }
        if predicate(status) {
            return status
        }
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    throw EngineError.listenTimeout
}

func queryNames(_ url: URL) throws -> [String] {
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    return try XCTUnwrap(components.queryItems).map(\.name)
}

func makeTemporaryDirectory() throws -> URL {
    let name = "umb-test-\(UUID().uuidString)"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    return url
}

func waitForPID(at url: URL, timeout: TimeInterval = 3) throws -> Int32 {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let pid = Int32(trimmed) {
                return pid
            }
        }
        usleep(20_000)
    }
    throw FixtureError.timedOut
}

func waitForDescendant(
    of root: Int32,
    containing needle: String,
    timeout: TimeInterval = 3
) throws -> Int32 {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        for line in ProcessTree.commandLines(root: root) {
            let parts = line.split(separator: "\0").map(String.init)
            if parts.contains(where: { $0.contains(needle) }) {
                if let pid = pidMatching(root: root, needle: needle) {
                    return pid
                }
            }
        }
        usleep(20_000)
    }
    throw FixtureError.timedOut
}

func pidMatching(root: Int32, needle: String) -> Int32? {
    var pending = [root]
    var seen = Set<Int32>()
    while let current = pending.popLast() {
        if !seen.insert(current).inserted {
            continue
        }
        let line = ProcessTree.commandLine(pid: current)
        if current != root, let line, line.contains(needle) {
            return current
        }
        pending.append(contentsOf: ProcessTree.children(of: current))
    }
    return nil
}

func waitUntilGone(_ pid: Int32, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if kill(pid, 0) != 0 {
            return true
        }
        usleep(50_000)
    }
    return kill(pid, 0) != 0
}

struct StubAria2 {
    let url: URL

    static func make() throws -> StubAria2 {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("aria2-stub.sh")
        let script = "#!/bin/sh\nsleep 30\n"
        try script.write(to: url, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return StubAria2(url: url)
    }
}
