// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@testable import UmbilicalEngine

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

struct CaptureUnavailable: Error, LocalizedError, CustomStringConvertible {
    var description: String {
        "packet capture did not run. Not verified: piece payload stops after "
            + "completion and the 1K cap on the wire. Still checked elsewhere: "
            + "seed-time=0, max-upload-limit=1K, and seed-ratio unset."
    }

    var errorDescription: String? {
        description
    }
}

final class RunningCapture {
    private let process: Process
    private let file: URL
    private let usedSudo: Bool
    private var stopped = false

    private init(process: Process, file: URL, usedSudo: Bool) {
        self.process = process
        self.file = file
        self.usedSudo = usedSudo
    }

    static func start(ports: [UInt16]) throws -> RunningCapture {
        guard let path = tcpdumpPath() else {
            throw CaptureUnavailable()
        }
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("umb.pcap")
        let iface = captureInterface()
        if let capture = try begin(
            path: path, sudo: false, iface: iface, file: file, ports: ports
        ) {
            return capture
        }
        if let capture = try begin(path: path, sudo: true, iface: iface, file: file, ports: ports) {
            return capture
        }
        throw CaptureUnavailable()
    }

    func stop() throws -> Data {
        interrupt()
        if usedSudo {
            _ = runQuiet(["/usr/bin/sudo", "-n", "chmod", "a+r", file.path])
        }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw CaptureUnavailable()
        }
        if data.count < 24 {
            throw CaptureUnavailable()
        }
        return data
    }

    func abandon() {
        interrupt()
    }

    private static func begin(
        path: String,
        sudo: Bool,
        iface: String,
        file: URL,
        ports: [UInt16]
    ) throws -> RunningCapture? {
        let process = Process()
        let dumpArgs = tcpdumpArguments(iface: iface, file: file.path, ports: ports)
        if sudo {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
            process.arguments = ["-n", path] + dumpArgs
        } else {
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = dumpArgs
        }
        process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        process.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try process.run()
        if waitForHeader(file: file, process: process) {
            return RunningCapture(process: process, file: file, usedSudo: sudo)
        }
        finish(process, file: file, sudo: sudo)
        return nil
    }

    private func interrupt() {
        if stopped {
            return
        }
        stopped = true
        if process.isRunning {
            kill(process.processIdentifier, SIGINT)
        }
        if usedSudo {
            _ = runQuiet(["/usr/bin/sudo", "-n", "pkill", "-INT", "-f", file.path])
        }
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}

private func tcpdumpPath() -> String? {
    for path in ["/usr/sbin/tcpdump", "/usr/bin/tcpdump"]
    where FileManager.default.isExecutableFile(atPath: path) {
        return path
    }
    return nil
}

private func captureInterface() -> String {
    #if os(Linux)
        return "any"
    #else
        return "lo0"
    #endif
}

private func tcpdumpArguments(iface: String, file: String, ports: [UInt16]) -> [String] {
    var args = ["-i", iface, "-n", "-s", "65535", "-U", "-w", file, "tcp", "and", "("]
    for (index, port) in ports.enumerated() {
        if index > 0 {
            args.append("or")
        }
        args.append("port")
        args.append(String(port))
    }
    args.append(")")
    return args
}

private func waitForHeader(file: URL, process: Process) -> Bool {
    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        if !process.isRunning {
            return false
        }
        if fileSize(file) >= 24 {
            return true
        }
        usleep(50_000)
    }
    return process.isRunning && fileSize(file) >= 24
}

private func fileSize(_ file: URL) -> Int {
    let attrs = try? FileManager.default.attributesOfItem(atPath: file.path)
    return (attrs?[.size] as? NSNumber)?.intValue ?? 0
}

private func finish(_ process: Process, file: URL, sudo: Bool) {
    if process.isRunning {
        kill(process.processIdentifier, SIGINT)
    }
    if sudo {
        _ = runQuiet(["/usr/bin/sudo", "-n", "pkill", "-INT", "-f", file.path])
    }
    let deadline = Date().addingTimeInterval(2)
    while process.isRunning && Date() < deadline {
        usleep(50_000)
    }
    if process.isRunning {
        kill(process.processIdentifier, SIGKILL)
    }
    process.waitUntilExit()
}

private func runQuiet(_ argv: [String]) -> Bool {
    guard let command = argv.first, argv.count > 1 else {
        return false
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: command)
    process.arguments = Array(argv.dropFirst())
    process.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
    process.standardError = FileHandle(forWritingAtPath: "/dev/null")
    do {
        try process.run()
    } catch {
        return false
    }
    process.waitUntilExit()
    return process.terminationStatus == 0
}
