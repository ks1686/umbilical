// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

public struct VideoDownloadProgress: Equatable {
    public enum Phase: Equatable {
        case running
        case finished
        case failed
        case cancelled
    }

    public var completed: Int64
    public var total: Int64
    public var speed: Int64
    public var phase: Phase
    public var filePath: String?
    public var message: String?

    public static let running = VideoDownloadProgress(
        completed: 0,
        total: 0,
        speed: 0,
        phase: .running,
        filePath: nil,
        message: nil
    )
}

/// One yt-dlp download. The argument list is built by `VideoDownloadPlan`.
public final class VideoDownloadJob {
    public let id: String
    public let url: URL
    public let outputName: String

    private let lock = NSLock()
    private let stdoutDone = DispatchSemaphore(value: 0)
    private let stderrDone = DispatchSemaphore(value: 0)
    private var progressState = VideoDownloadProgress.running
    private var tailLines: [String] = []
    private var process: Process?
    private var cancelled = false
    private var didFinish = false
    private let staging: URL
    private let folder: URL
    private let root: URL
    private let quarantine: any QuarantineApplying

    public static func start(
        ytDlp: URL,
        watch: URL,
        urlText: String,
        outputName: String,
        directory: URL?,
        root: URL,
        quarantine: any QuarantineApplying = SystemQuarantine()
    ) throws -> VideoDownloadJob {
        if !FileManager.default.isExecutableFile(atPath: ytDlp.path) {
            throw EngineError.executableMissing("yt-dlp")
        }
        if !FileManager.default.isExecutableFile(atPath: watch.path) {
            throw EngineError.executableMissing("umb-watch")
        }
        let target = try VideoDownloadPlan.target(
            urlText: urlText,
            outputName: outputName,
            directory: directory,
            root: root
        )
        let staging = try VideoDownloadPlan.makeStagingDirectory(in: target.folder)
        let arguments: [String]
        do {
            arguments = try VideoDownloadPlan.arguments(for: target, stagingDirectory: staging)
        } catch {
            VideoDownloadCleanup.removeStaging(staging)
            throw error
        }
        let job = VideoDownloadJob(
            url: target.url,
            outputName: target.outputName ?? "",
            staging: staging,
            folder: target.folder,
            root: target.root,
            quarantine: quarantine
        )
        do {
            try job.launch(watch: watch, ytDlp: ytDlp, arguments: arguments, staging: staging)
        } catch {
            VideoDownloadCleanup.removeStaging(staging)
            throw error
        }
        return job
    }

    public func progress() -> VideoDownloadProgress {
        lock.lock()
        let copy = progressState
        lock.unlock()
        return copy
    }

    public func cancel() {
        let running = markCancelled()
        guard let running else {
            return
        }
        terminate(running)
    }

    private init(
        url: URL,
        outputName: String,
        staging: URL,
        folder: URL,
        root: URL,
        quarantine: any QuarantineApplying
    ) {
        self.id = "video-\(UUID().uuidString.lowercased())"
        self.url = url
        self.outputName = outputName
        self.staging = staging
        self.folder = folder
        self.root = root
        self.quarantine = quarantine
    }

    private func launch(watch: URL, ytDlp: URL, arguments: [String], staging: URL) throws {
        let process = Process()
        process.executableURL = watch
        process.arguments = [ytDlp.path] + arguments
        process.environment = VideoDownloadPlan.childEnvironment(home: staging.path)
        let output = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = output
        process.standardError = errorPipe
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
        let outputHandle = output.fileHandleForReading
        let errorHandle = errorPipe.fileHandleForReading
        pump(outputHandle, done: stdoutDone, captureTail: false)
        pump(errorHandle, done: stderrDone, captureTail: true)
        do {
            try process.run()
        } catch {
            closeWrite(output)
            closeWrite(errorPipe)
            waitForPumps()
            throw EngineError.launchFailed(error.localizedDescription)
        }
        closeWrite(output)
        closeWrite(errorPipe)
        lock.lock()
        self.process = process
        let alreadyCancelled = cancelled
        lock.unlock()
        let thread = Thread {
            process.waitUntilExit()
            self.finish(process)
        }
        thread.start()
        if alreadyCancelled {
            terminate(process)
        }
    }

    private func pump(_ handle: FileHandle, done: DispatchSemaphore, captureTail: Bool) {
        let thread = Thread {
            self.drain(handle, done: done, captureTail: captureTail)
        }
        thread.start()
    }

    private func drain(_ handle: FileHandle, done: DispatchSemaphore, captureTail: Bool) {
        var pending = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty {
                break
            }
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 0x0A) {
                let lineData = pending.prefix(upTo: newline)
                pending.removeSubrange(0...newline)
                var text = String(decoding: lineData, as: UTF8.self)
                if text.hasSuffix("\r") {
                    text.removeLast()
                }
                if let parsed = VideoProgressParser.parse(text) {
                    note(parsed)
                }
                if captureTail {
                    remember(text)
                }
            }
            if pending.count > 65_536 {
                pending.removeAll()
            }
        }
        done.signal()
    }

    private func note(_ parsed: (completed: Int64, total: Int64, speed: Int64)) {
        lock.lock()
        if progressState.phase == .running {
            progressState.completed = parsed.completed
            progressState.total = parsed.total
            progressState.speed = parsed.speed
        }
        lock.unlock()
    }

    private func remember(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return
        }
        lock.lock()
        tailLines.append(trimmed)
        if tailLines.count > 20 {
            tailLines.removeFirst(tailLines.count - 20)
        }
        lock.unlock()
    }

    private func finish(_ process: Process) {
        lock.lock()
        if didFinish {
            lock.unlock()
            return
        }
        didFinish = true
        let wasCancelled = cancelled
        lock.unlock()
        waitForPumps()
        if wasCancelled || process.terminationReason == .uncaughtSignal {
            VideoDownloadCleanup.removeStaging(staging)
            publish(
                VideoDownloadProgress(
                    completed: progress().completed,
                    total: progress().total,
                    speed: 0,
                    phase: .cancelled,
                    filePath: nil,
                    message: "Cancelled."
                )
            )
            return
        }
        if process.terminationStatus != 0 {
            VideoDownloadCleanup.removeStaging(staging)
            publish(
                VideoDownloadProgress(
                    completed: progress().completed,
                    total: progress().total,
                    speed: 0,
                    phase: .failed,
                    filePath: nil,
                    message: VideoDownloadPlan.failureMessage(from: tailLinesCopy())
                )
            )
            return
        }
        if isCancelled() {
            VideoDownloadCleanup.removeStaging(staging)
            publish(
                VideoDownloadProgress(
                    completed: progress().completed,
                    total: progress().total,
                    speed: 0,
                    phase: .cancelled,
                    filePath: nil,
                    message: "Cancelled."
                )
            )
            return
        }
        do {
            let file = try VideoDownloadFinisher.adopt(
                staging: staging,
                folder: folder,
                root: root,
                outputName: outputName.isEmpty ? nil : outputName,
                quarantine: quarantine
            )
            let latest = progress()
            publish(
                VideoDownloadProgress(
                    completed: latest.completed,
                    total: max(latest.total, latest.completed),
                    speed: 0,
                    phase: .finished,
                    filePath: file.path,
                    message: nil
                )
            )
        } catch {
            VideoDownloadCleanup.removeStaging(staging)
            publish(
                VideoDownloadProgress(
                    completed: progress().completed,
                    total: progress().total,
                    speed: 0,
                    phase: .failed,
                    filePath: nil,
                    message: failureText(error)
                )
            )
        }
    }

    private func publish(_ progress: VideoDownloadProgress) {
        lock.lock()
        progressState = progress
        lock.unlock()
    }

    private func failureText(_ error: Error) -> String {
        if let engine = error as? EngineError {
            return engine.description
        }
        return "The video download failed."
    }

    private func tailLinesCopy() -> [String] {
        lock.lock()
        let copy = tailLines
        lock.unlock()
        return copy
    }

    private func isCancelled() -> Bool {
        lock.lock()
        let value = cancelled
        lock.unlock()
        return value
    }

    private func markCancelled() -> Process? {
        lock.lock()
        cancelled = true
        let running = process
        lock.unlock()
        return running
    }

    private func terminate(_ process: Process) {
        let pid = process.processIdentifier
        if process.isRunning {
            process.terminate()
        }
        waitUntilStopped(process, seconds: 2)
        if process.isRunning && pid > 1 {
            signalTree(pid, SIGKILL)
            kill(pid, SIGKILL)
            waitUntilStopped(process, seconds: 1)
        }
    }

    private func waitUntilStopped(_ process: Process, seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while process.isRunning && Date() < deadline {
            usleep(20_000)
        }
    }

    private func signalTree(_ pid: Int32, _ signal: Int32) {
        var pending = [pid]
        var seen = Set<Int32>()
        var victims: [Int32] = []
        while let current = pending.popLast() {
            if current <= 1 || !seen.insert(current).inserted {
                continue
            }
            victims.append(current)
            pending.append(contentsOf: ProcessTree.children(of: current))
        }
        for victim in victims.reversed() where victim != pid {
            kill(victim, signal)
        }
    }

    private func closeWrite(_ pipe: Pipe) {
        pipe.fileHandleForWriting.closeFile()
    }

    private func waitForPumps() {
        _ = stdoutDone.wait(timeout: .now() + 2)
        _ = stderrDone.wait(timeout: .now() + 2)
    }
}
