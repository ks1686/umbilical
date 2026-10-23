// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UmbilicalEngine
import UmbilicalUI

@main
struct UmbilicalApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var updates = UpdateController()
    @NSApplicationDelegateAdaptor(AppTermination.self) private var termination

    var body: some Scene {
        Window("umbilical", id: "main") {
            ContentView(model: model)
                .onOpenURL { url in
                    model.receiveExternalURL(url)
                }
        }
        .defaultSize(width: 760, height: 520)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates") {
                    updates.checkForUpdates()
                }
            }
        }

        MenuBarExtra {
            MenuBarMenu(model: model, updates: updates)
        } label: {
            MenuBarTitle(model: model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class AppTermination: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    private static var queued: [URL] = []

    static func attach(_ model: AppModel) {
        self.model = model
        let pending = queued
        queued.removeAll()
        for url in pending {
            model.receiveExternalURL(url)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        closeRestoredExtraWindows()
        // Safari's state API can error before the window exists. Retry
        // after launch without blocking startup.
        AppTermination.model?.refreshSafariNotice()
        MenuBarStatusItem.applyToOpenStatusButtons()
        DispatchQueue.main.async {
            MenuBarStatusItem.applyToOpenStatusButtons()
        }
    }

    func applicationWillTerminate(_: Notification) {
        MacActions.beginTermination()
        for window in NSApp.windows {
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
        }
        AppTermination.model?.stop()
    }

    // Torrent and metalink document types would otherwise make AppKit open a
    // blank untitled window behind the main scene on launch and URL handoff.
    func applicationShouldOpenUntitledFile(_: NSApplication) -> Bool {
        false
    }

    /// Unique `Window(id: "main")` does not drop Saved Application State from
    /// an older multi-instance window scene. `restorationBehavior` is macOS 15
    /// or later, so extras are closed here and Resume is off in Info.plist.
    private func closeRestoredExtraWindows() {
        let snapshots = NSApp.windows.map { window in
            RestoredWindowFilter.Snapshot(
                title: window.title,
                identifier: window.identifier?.rawValue ?? "",
                isPanel: window is NSPanel,
                canBecomeMain: window.canBecomeMain
            )
        }
        let closing = Set(RestoredWindowFilter.indicesToClose(snapshots))
        for (index, window) in NSApp.windows.enumerated() where closing.contains(index) {
            window.isRestorable = false
            if let sheet = window.attachedSheet {
                window.endSheet(sheet)
            }
            window.close()
        }
    }

    func application(_: NSApplication, open urls: [URL]) {
        for url in urls {
            if let model = AppTermination.model {
                model.receiveExternalURL(url)
            } else {
                AppTermination.queued.append(url)
            }
        }
    }
}
