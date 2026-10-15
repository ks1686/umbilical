// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

enum MacActions {
    static func chooseDirectory(startingAt: URL?, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = message
        panel.directoryURL = startingAt
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    static func clipboardText() -> String? {
        guard let raw = NSPasteboard.general.string(forType: .string) else {
            return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return nil
        }
        return trimmed
    }

    static func reveal(_ path: String) {
        guard FileManager.default.fileExists(atPath: path) else { return }
        let url = URL(fileURLWithPath: path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    static func activate() {
        NSRunningApplication.current.activate(
            from: nil,
            options: [.activateAllWindows]
        )
    }

    static func terminate() {
        NSApp.terminate(nil)
    }
}
