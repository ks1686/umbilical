// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum RPCOptionPolicy {
    static let allowed: Set<String> = [
        "out",
        "select-file",
        "max-download-limit",
        "split",
        "dir",
        "follow-metalink"
    ]

    static func validate(_ options: [String: String], downloadRoot: URL) throws {
        for (key, value) in options {
            if key.lowercased().hasPrefix("on-") {
                throw EngineError.hookRejected(key)
            }
            guard allowed.contains(key) else {
                throw EngineError.optionRejected(key)
            }
            switch key {
            case "out":
                try DownloadPath.validateOutputName(value)
            case "dir":
                _ = try DownloadPath.resolveInside(root: downloadRoot, raw: value)
            case "split":
                try DownloadPath.validateSplit(value)
            case "max-download-limit":
                try DownloadPath.validateRate(value)
            case "select-file":
                try DownloadPath.validateSelectFile(value)
            case "follow-metalink":
                try DownloadPath.validateFollowMetalink(value)
            default:
                throw EngineError.optionRejected(key)
            }
        }
    }
}
