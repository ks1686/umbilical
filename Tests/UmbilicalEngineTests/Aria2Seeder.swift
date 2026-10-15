// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class Aria2Seeder {
    let listenPort: UInt16
    private let process = Process()
    private let errFile: URL
    private var outputHandle: FileHandle?

    init(aria2: URL, directory: URL, torrent: URL, listenPort: UInt16) throws {
        self.listenPort = listenPort
        self.errFile = directory.appendingPathComponent("seeder.err")
        let conf = directory.appendingPathComponent("seeder.conf")
        try seederConfig(directory: directory, listenPort: listenPort).write(
            to: conf,
            atomically: false,
            encoding: .utf8
        )
        if !FileManager.default.createFile(atPath: errFile.path, contents: nil) {
            throw TrialFailure(description: "could not create seeder log")
        }
        let handle = try FileHandle(forWritingTo: errFile)
        self.outputHandle = handle
        process.executableURL = aria2
        process.arguments = ["--conf-path", conf.path, torrent.path]
        process.standardOutput = handle
        process.standardError = handle
        process.standardInput = FileHandle(forReadingAtPath: "/dev/null")
    }

    func start() throws {
        try process.run()
        usleep(300_000)
        if !process.isRunning {
            throw TrialFailure(description: "seeder exited: \(output())")
        }
    }

    func stop() {
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                usleep(20_000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
        }
        try? outputHandle?.close()
        outputHandle = nil
    }

    func output() -> String {
        guard let data = try? Data(contentsOf: errFile) else {
            return ""
        }
        let text = String(bytes: data, encoding: .utf8) ?? ""
        if text.count > 2000 {
            return String(text.prefix(2000))
        }
        return text
    }
}

private func seederConfig(directory: URL, listenPort: UInt16) -> String {
    [
        "dir=\(directory.path)",
        "seed-time=30",
        "seed-ratio=100",
        "enable-dht=false",
        "enable-peer-exchange=false",
        "bt-enable-lpd=false",
        "listen-port=\(listenPort)",
        "max-upload-limit=0",
        "check-integrity=true",
        "bt-hash-check-seed=true",
        "console-log-level=warn",
        "enable-rpc=false",
        "summary-interval=0",
        "disable-ipv6=true",
        ""
    ].joined(separator: "\n")
}
