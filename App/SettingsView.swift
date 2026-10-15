// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UmbilicalUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var folderError: String?

    var body: some View {
        Form {
            downloadsSection
            notificationsSection
            helpersSection
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .padding()
    }

    private var downloadsSection: some View {
        Section("Downloads") {
            LabeledContent("Folder") {
                VStack(alignment: .trailing, spacing: 6) {
                    Text(folderText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .multilineTextAlignment(.trailing)
                    Button("Choose…") { choose() }
                }
            }
            Text(
                "Every download stays inside this folder. Active downloads stop when umbilical quits."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if let folderError {
                Text(folderError)
                    .foregroundStyle(.red)
            }
        }
    }

    private var notificationsSection: some View {
        Section("Notifications") {
            Toggle(
                "When a download finishes",
                isOn: Binding(
                    get: { model.snapshot.notifyOnComplete },
                    set: { model.setNotifyOnComplete($0) }
                )
            )
            Toggle(
                "When a download fails",
                isOn: Binding(
                    get: { model.snapshot.notifyOnFailure },
                    set: { model.setNotifyOnFailure($0) }
                )
            )
        }
    }

    private var helpersSection: some View {
        Section("Helpers") {
            LabeledContent("aria2c") {
                Text(model.snapshot.helpers.aria2Found ? "Ready" : "Not found")
            }
            LabeledContent("umb-watch") {
                Text(model.snapshot.helpers.watchFound ? "Ready" : "Not found")
            }
            Text(
                "Build aria2c with scripts/build-aria2.sh. "
                    + "The app checks ARIA2C and Contents/Helpers/aria2c."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    private var folderText: String {
        model.snapshot.downloadDirectoryPath ?? "Not set"
    }

    private func choose() {
        guard
            let picked = MacActions.chooseDirectory(
                startingAt: model.downloadDirectory,
                message: "umbilical saves every download inside this folder."
            )
        else { return }
        Task {
            folderError = await model.useRoot(picked)
        }
    }
}
