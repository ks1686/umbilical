// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(spacing: 12) {
            Text("umbilical")
                .font(.title)
            Text(UmbilicalMarker.shortName)
                .font(.headline)
            Text(EngineStub.status)
                .foregroundStyle(.secondary)
        }
        .padding(24)
        .frame(minWidth: 320, minHeight: 180)
    }
}
