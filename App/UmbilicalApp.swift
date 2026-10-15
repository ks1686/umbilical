// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct UmbilicalApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppTermination.self) private var termination

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView(model: model)
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

    func applicationWillTerminate(_: Notification) {
        AppTermination.model?.stop()
    }
}
