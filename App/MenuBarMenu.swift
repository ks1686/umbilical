// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UmbilicalUI

struct MenuBarTitle: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text(model.snapshot.menuTitle)
            .monospacedDigit()
    }
}

struct MenuBarMenu: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        if model.snapshot.menuRows.isEmpty {
            Text("No active downloads")
        } else {
            ForEach(model.snapshot.menuRows) { row in
                Text(row.label)
            }
        }
        Divider()
        Button("Open umbilical") { showMainWindow() }
        Button("Settings…") { showSettings() }
        Divider()
        Button("Quit umbilical") { quit() }
    }

    private func showMainWindow() {
        MacActions.activate()
        openWindow(id: "main")
    }

    private func showSettings() {
        MacActions.activate()
        openSettings()
    }

    private func quit() {
        model.stop()
        MacActions.terminate()
    }
}
