// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UmbilicalEngine

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

    func applicationWillTerminate(_: Notification) {
        AppTermination.model?.stop()
    }

    // Torrent and metalink document types would otherwise make AppKit open a
    // blank untitled window behind the main scene on launch and URL handoff.
    func applicationShouldOpenUntitledFile(_: NSApplication) -> Bool {
        false
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
