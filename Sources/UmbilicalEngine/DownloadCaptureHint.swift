// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// File-name hints used after a Safari click or a Finder open.
/// The content script keeps its own copy of the extension list.
public enum DownloadCaptureHint {
    public static let torrentExtensions: Set<String> = ["torrent"]
    public static let metalinkExtensions: Set<String> = ["metalink", "meta4"]
    public static let fileExtensions: Set<String> = [
        "7z", "apk", "avi", "azw3", "bin", "bz2", "csv", "deb", "dmg", "doc", "docx",
        "epub", "exe", "flac", "gz", "ics", "iso", "jar", "m4a", "mka", "mkv", "mov",
        "mp3", "mp4", "msi", "odt", "ogg", "ogv", "pdf", "pkg", "ppt", "pptx", "rar",
        "rpm", "rtf", "tar", "tbz2", "tgz", "torrent", "txt", "wav", "webm", "wma",
        "wmv", "xls", "xlsx", "xz", "zip", "zst", "metalink", "meta4"
    ]

    public static func pathExtension(url: URL, filename: String?) -> String? {
        if let filename, let ext = extensionOf(filename) {
            return ext
        }
        return extensionOf(url.lastPathComponent)
    }

    public static func isTorrent(url: URL, filename: String?) -> Bool {
        torrentExtensions.contains(pathExtension(url: url, filename: filename) ?? "")
    }

    public static func isMetalink(url: URL, filename: String?) -> Bool {
        metalinkExtensions.contains(pathExtension(url: url, filename: filename) ?? "")
    }

    public static func looksLikeDownload(url: URL, filename: String?) -> Bool {
        fileExtensions.contains(pathExtension(url: url, filename: filename) ?? "")
    }

    private static func extensionOf(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let dot = trimmed.lastIndex(of: ".") else {
            return nil
        }
        let ext = String(trimmed[trimmed.index(after: dot)...]).lowercased()
        if ext.isEmpty || ext.contains("/") || ext.contains("\\") {
            return nil
        }
        return ext
    }
}
