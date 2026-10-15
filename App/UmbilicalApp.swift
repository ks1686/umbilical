// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

@main
struct UmbilicalApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        MenuBarExtra(UmbilicalMarker.shortName) {
            Text(UmbilicalMarker.shortName)
        }
    }
}
