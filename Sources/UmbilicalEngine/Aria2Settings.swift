// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum Aria2Settings {
    static let maxUploadLimit = "1K"
    static let btMaxPeers = 50

    static func render(secret: String, port: UInt16, downloadDirectory: String) throws -> String {
        guard secret.count == 64, secret.allSatisfy(\.isHexDigit) else {
            throw EngineError.settingsWriteFailed("secret format")
        }
        guard !downloadDirectory.contains("\n"), !downloadDirectory.contains("\r"), !downloadDirectory.contains("\0") else {
            throw EngineError.directoryRejected(downloadDirectory)
        }
        let lines = [
            "allow-overwrite=false",
            "auto-file-renaming=true",
            "bt-max-peers=\(btMaxPeers)",
            "check-certificate=true",
            "check-integrity=true",
            "console-log-level=warn",
            "dir=\(downloadDirectory)",
            "enable-dht=true",
            "enable-peer-exchange=true",
            "enable-rpc=true",
            "max-upload-limit=\(maxUploadLimit)",
            "rpc-allow-origin-all=false",
            "rpc-listen-all=false",
            "rpc-listen-port=\(port)",
            "rpc-secret=\(secret)",
            "seed-ratio=0.0",
            "seed-time=0",
            "summary-interval=0",
        ]
        return lines.joined(separator: "\n") + "\n"
    }
}
