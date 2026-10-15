// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalEngine

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class EngineSupervisorTests: XCTestCase {
    func testLossyProcessTextKeepsASCIIAndReplacesInvalidBytes() {
        var bytes = Array("PATH=/bin\0name=".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: "\0sleep".utf8)
        let text = ProcessTree.lossyText(Data(bytes))
        XCTAssertTrue(text.contains("PATH=/bin"))
        XCTAssertTrue(text.contains("sleep"))
        XCTAssertTrue(text.contains("?"))
        XCTAssertFalse(text.contains("--rpc-secret"))
    }

    func testSecretNeverAppearsInProcessArgumentsAndSettingsFileIsPrivate() async throws {
        let previous = umask(0)
        defer { _ = umask(previous) }
        let downloads = try makeTemporaryDirectory()
        let stub = try StubAria2.make()
        defer {
            try? FileManager.default.removeItem(at: downloads)
            try? FileManager.default.removeItem(at: stub.url.deletingLastPathComponent())
        }
        let supervisor = EngineSupervisor(
            aria2Executable: stub.url,
            downloadDirectory: downloads,
            watchHelper: try TestBins.watchHelper(),
            quarantine: RecordingQuarantine()
        )
        defer { supervisor.stop() }
        let prepared = try supervisor.prepareLaunch()
        XCTAssertEqual(try POSIX.permissions(of: prepared.directory.path), 0o700)
        XCTAssertEqual(try POSIX.permissions(of: prepared.settingsFile.path), 0o600)
        XCTAssertEqual(prepared.arguments, ["--conf-path", prepared.settingsFile.path])
        let joinedArguments = prepared.arguments.joined(separator: "\0")
        XCTAssertFalse(joinedArguments.contains(prepared.secret))
        XCTAssertFalse(joinedArguments.contains("rpc-secret"))
        let settings = try String(contentsOf: prepared.settingsFile, encoding: .utf8)
        XCTAssertTrue(settings.contains("rpc-secret=\(prepared.secret)"))
        let client = try await supervisor.completeLaunch(prepared, probe: ImmediateProbe())
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.settingsFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.directory.path))
        let pid = try XCTUnwrap(supervisor.processIdentifier)
        XCTAssertEqual(client.port, prepared.port)
        let blobs = ProcessTree.snapshot(root: pid)
        XCTAssertFalse(blobs.isEmpty)
        for blob in blobs {
            XCTAssertFalse(blob.contains(prepared.secret))
            XCTAssertFalse(blob.contains("rpc-secret"))
        }
        let lines = ProcessTree.commandLines(root: pid)
        let settingsPath = prepared.settingsFile.path
        let sawConfig = lines.contains { line in
            line.contains("--conf-path") && line.contains(settingsPath)
        }
        XCTAssertTrue(sawConfig)
        _ = client
    }

    func testChildExitsWhenParentExits() throws {
        let watch = try TestBins.watchHelper()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("parent.sh")
        let parentFile = directory.appendingPathComponent("parent.pid")
        let watchFile = directory.appendingPathComponent("watch.pid")
        let body = """
            #!/bin/sh
            echo $$ > "$1"
            "$2" /bin/sleep 120 &
            echo $! > "$3"
            wait
            """
        try body.write(to: script, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let parent = Process()
        parent.executableURL = URL(fileURLWithPath: "/bin/sh")
        parent.arguments = [script.path, parentFile.path, watch.path, watchFile.path]
        try parent.run()
        let watchPID = try waitForPID(at: watchFile)
        let sleepPID = try waitForDescendant(of: watchPID, containing: "sleep")
        defer {
            if kill(sleepPID, 0) == 0 { kill(sleepPID, SIGKILL) }
            if kill(watchPID, 0) == 0 { kill(watchPID, SIGKILL) }
            if parent.isRunning { parent.terminate() }
        }
        parent.terminate()
        XCTAssertTrue(waitUntilGone(sleepPID))
    }

    func testAria2ReceivesParentDeathSignalOnLinux() throws {
        #if !os(Linux)
            throw XCTSkip("PR_SET_PDEATHSIG is Linux-only")
        #else
            let watch = try TestBins.watchHelper()
            let process = Process()
            process.executableURL = watch
            process.arguments = ["/bin/sleep", "120"]
            try process.run()
            let watchPID = process.processIdentifier
            let sleepPID = try waitForDescendant(of: watchPID, containing: "sleep")
            defer {
                if kill(sleepPID, 0) == 0 { kill(sleepPID, SIGKILL) }
                if kill(watchPID, 0) == 0 { kill(watchPID, SIGKILL) }
            }
            kill(watchPID, SIGKILL)
            XCTAssertTrue(waitUntilGone(sleepPID))
        #endif
    }
}
