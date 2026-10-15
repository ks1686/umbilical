// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UmbilicalEngine

@main
struct UmbilicalApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppTermination.self) private var termination

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
                .onOpenURL { url in
                    model.receiveExternalURL(url)
                }
        }
        .defaultSize(width: 760, height: 520)

        MenuBarExtra {
            MenuBarMenu(model: model)
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

    func application(_: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme?.lowercased() == ExternalDownload.scheme {
            if let model = AppTermination.model {
                model.receiveExternalURL(url)
            } else {
                AppTermination.queued.append(url)
            }
        }
    }
}
