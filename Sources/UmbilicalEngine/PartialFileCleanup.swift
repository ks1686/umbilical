// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum PartialFileCleanup {
    public static func deletablePaths(files: [URL], downloadDirectory: URL) -> [String] {
        var found: [String] = []
        var seen: Set<String> = []
        for file in files {
            let raw = file.path
            if raw.isEmpty {
                continue
            }
            appendIfDeletable(raw, root: downloadDirectory, into: &found, seen: &seen)
            appendIfDeletable(raw + ".aria2", root: downloadDirectory, into: &found, seen: &seen)
        }
        return found
    }

    public static func delete(files: [URL], downloadDirectory: URL) {
        for path in deletablePaths(files: files, downloadDirectory: downloadDirectory) {
            try? POSIX.removeFile(path)
        }
    }

    private static func appendIfDeletable(
        _ raw: String,
        root: URL,
        into found: inout [String],
        seen: inout Set<String>
    ) {
        guard let path = try? DownloadPath.deletableRegularFile(root: root, raw: raw) else {
            return
        }
        if seen.insert(path).inserted {
            found.append(path)
        }
    }
}
