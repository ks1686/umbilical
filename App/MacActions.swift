// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import UmbilicalUI

enum MacActions {
    private static var presentingAlert = false
    private static var terminating = false

    static func beginTermination() {
        terminating = true
        presentingAlert = false
    }

    /// One app-wide rejection alert. SwiftUI `.alert` on ContentView would
    /// show once in every restored window.
    static func presentRejectedDownload(_ message: String, onDismiss: @escaping () -> Void) {
        guard
            AppAlertGate.shouldPresent(
                message: message,
                alreadyPresenting: presentingAlert,
                terminating: terminating
            )
        else { return }
        presentingAlert = true
        let alert = NSAlert()
        alert.messageText = "Download rejected"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        let finish = {
            presentingAlert = false
            onDismiss()
        }
        let host = NSApp.mainWindow ?? NSApp.keyWindow
        if let window = host, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { _ in finish() }
        } else {
            _ = alert.runModal()
            finish()
        }
    }

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
            from: NSRunningApplication.current,
            options: [.activateAllWindows]
        )
    }

    static func terminate() {
        NSApp.terminate(nil)
    }
}
