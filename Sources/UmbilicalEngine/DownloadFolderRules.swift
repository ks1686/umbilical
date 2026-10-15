// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum DownloadFolderRules {
    public static func resolveInside(root: URL, raw: String) throws -> String {
        try DownloadPath.resolveInside(root: root, raw: raw)
    }

    public static func acceptRoot(_ folder: URL) throws -> URL {
        try requireDirectory(folder)
        let resolved = try DownloadPath.resolveInside(root: folder, raw: folder.path)
        return URL(fileURLWithPath: resolved, isDirectory: true)
    }

    public static func acceptChild(_ folder: URL, root: URL) throws -> URL {
        let resolved = try DownloadPath.resolveInside(root: root, raw: folder.path)
        let url = URL(fileURLWithPath: resolved, isDirectory: true)
        try requireDirectory(url)
        return url
    }

    private static func requireDirectory(_ folder: URL) throws {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: folder.path,
            isDirectory: &isDirectory
        )
        if !exists || !isDirectory.boolValue {
            throw EngineError.directoryRejected(folder.path)
        }
    }
}
