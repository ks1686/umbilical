// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct PreparedLaunch {
    let directory: URL
    let settingsFile: URL
    let secret: String
    let port: UInt16
    let arguments: [String]
    let downloadRoot: String
}

protocol RPCListening {
    func isListening(port: UInt16, secret: String) async -> Bool
}

struct LiveRPCProbe: RPCListening {
    func isListening(port: UInt16, secret: String) async -> Bool {
        let transport = LoopbackTransport(port: port, timeoutSeconds: 2)
        let client = RPCClient(
            port: port,
            secret: secret,
            downloadDirectory: URL(fileURLWithPath: "/"),
            transport: transport,
            quarantine: SystemQuarantine()
        )
        return (try? await client.version()) != nil
    }
}

public final class EngineSupervisor {
    private let aria2Executable: URL
    private let watchHelper: URL
    private let downloadDirectory: URL
    private let quarantine: any QuarantineApplying
    private var process: Process?
    private var stderrDrain: PipeDrain?
    var listenTimeout: TimeInterval = 8

    public init(
        aria2Executable: URL,
        downloadDirectory: URL,
        watchHelper: URL,
        quarantine: any QuarantineApplying = SystemQuarantine()
    ) {
        self.aria2Executable = aria2Executable
        self.downloadDirectory = downloadDirectory
        self.watchHelper = watchHelper
        self.quarantine = quarantine
    }

    public func start() async throws -> RPCClient {
        try await start(probe: LiveRPCProbe())
    }

    func start(probe: any RPCListening) async throws -> RPCClient {
        var lastError: Error = EngineError.listenTimeout
        for _ in 0..<4 {
            let prepared = try prepareLaunch()
            do {
                return try await completeLaunch(prepared, probe: probe)
            } catch EngineError.executableMissing {
                throw EngineError.executableMissing(aria2Executable.path)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    func prepareLaunch() throws -> PreparedLaunch {
        guard FileManager.default.isExecutableFile(atPath: aria2Executable.path) else {
            throw EngineError.executableMissing(aria2Executable.path)
        }
        guard FileManager.default.isExecutableFile(atPath: watchHelper.path) else {
            throw EngineError.executableMissing(watchHelper.path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: downloadDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw EngineError.directoryRejected(downloadDirectory.path)
        }
        let resolvedRoot = try DownloadPath.resolveInside(root: downloadDirectory, raw: downloadDirectory.path)
        let directory = URL(fileURLWithPath: try POSIX.makePrivateDirectory(), isDirectory: true)
        let settings = directory.appendingPathComponent("aria2.conf")
        do {
            let secret = try makeSecret()
            let port = try POSIX.freeLoopbackPort()
            let body = try Aria2Settings.render(secret: secret, port: port, downloadDirectory: resolvedRoot)
            try POSIX.writeNewFile(path: settings.path, contents: Data(body.utf8))
            return PreparedLaunch(
                directory: directory,
                settingsFile: settings,
                secret: secret,
                port: port,
                arguments: ["--conf-path", settings.path],
                downloadRoot: resolvedRoot
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    func completeLaunch(_ prepared: PreparedLaunch, probe: any RPCListening) async throws -> RPCClient {
        let process = Process()
        process.executableURL = watchHelper
        process.arguments = [aria2Executable.path] + prepared.arguments
        let drain = Pipe()
        process.standardError = drain
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        let collector = PipeDrain(handle: drain.fileHandleForReading)
        var needsCleanup = true
        defer {
            if needsCleanup {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
                if self.process === process {
                    self.process = nil
                }
                try? POSIX.removeFile(prepared.settingsFile.path)
                try? FileManager.default.removeItem(at: prepared.directory)
                collector.stop()
            }
        }
        do {
            try process.run()
        } catch {
            throw EngineError.launchFailed(error.localizedDescription)
        }
        self.process = process
        self.stderrDrain = collector
        if ProcessTree.containsSecret(root: process.processIdentifier, secret: prepared.secret) {
            throw EngineError.secretExposed
        }
        let deadline = Date().addingTimeInterval(listenTimeout)
        var listening = false
        while Date() < deadline {
            if !process.isRunning {
                throw EngineError.launchFailed(collector.text(redacting: prepared.secret))
            }
            if await probe.isListening(port: prepared.port, secret: prepared.secret) {
                listening = true
                break
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if !listening {
            throw EngineError.listenTimeout
        }
        if ProcessTree.containsSecret(root: process.processIdentifier, secret: prepared.secret) {
            throw EngineError.secretExposed
        }
        try POSIX.removeFile(prepared.settingsFile.path)
        try? FileManager.default.removeItem(at: prepared.directory)
        needsCleanup = false
        return RPCClient(
            port: prepared.port,
            secret: prepared.secret,
            downloadDirectory: URL(fileURLWithPath: prepared.downloadRoot, isDirectory: true),
            transport: LoopbackTransport(port: prepared.port),
            quarantine: quarantine
        )
    }

    public func stop() {
        if let process, process.isRunning {
            let pid = process.processIdentifier
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if process.isRunning && pid > 0 {
                kill(pid, SIGKILL)
            }
            process.waitUntilExit()
        }
        process = nil
        stderrDrain?.stop()
        stderrDrain = nil
    }

    func launchOutput(redacting secret: String) -> String {
        stderrDrain?.text(redacting: secret) ?? ""
    }

    var processIdentifier: Int32? {
        guard let process, process.isRunning else { return nil }
        return process.processIdentifier
    }

    private func makeSecret() throws -> String {
        let bytes = try POSIX.randomBytes(count: 32)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

final class PipeDrain {
    private let handle: FileHandle
    private let buffer = LockedData()
    private let thread: Thread

    init(handle: FileHandle) {
        self.handle = handle
        let buffer = self.buffer
        let thread = Thread {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty {
                    break
                }
                buffer.append(chunk)
            }
        }
        self.thread = thread
        thread.start()
    }

    func text(redacting secret: String) -> String {
        var value = String(decoding: buffer.copy(), as: UTF8.self)
        if !secret.isEmpty {
            value = value.replacingOccurrences(of: secret, with: "[redacted]")
        }
        if value.count > 2000 {
            return String(value.prefix(2000))
        }
        return value
    }

    func stop() {
        try? handle.close()
    }
}

private final class LockedData {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func copy() -> Data {
        lock.lock()
        let copy = data
        lock.unlock()
        return copy
    }
}
