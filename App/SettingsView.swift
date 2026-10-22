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
            LicenseSettingsSection(model: model)
            downloadsSection
            safariSection
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
                "Every download stays inside this folder. "
                    + "Active downloads stop when umbilical quits."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            if let folderError {
                Text(folderError)
                    .foregroundStyle(.red)
            }
        }
    }

    private var safariSection: some View {
        Section("Safari") {
            Text(
                "Right-click a link for Download with umbilical. Safari hides that item "
                    + "until website access is allowed. Click the umbilical toolbar button "
                    + "and choose Allow website access, or turn it on in Safari Settings > "
                    + "Extensions > umbilical."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
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
            LabeledContent("yt-dlp") {
                Text(model.snapshot.helpers.ytDlpFound ? "Ready" : "Not found")
            }
            Text(
                "Build aria2c with scripts/build-aria2.sh. "
                    + "Fetch yt-dlp with scripts/fetch-helpers.sh. "
                    + "Release builds use Contents/Helpers only. "
                    + "Debug builds also honor ARIA2C, UMB_WATCH, and YT_DLP."
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
