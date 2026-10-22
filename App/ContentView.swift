// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UmbilicalUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var showingAdd = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                unofficialCaption
                SafariExtensionNoticeBanner(notice: model.safariNotice)
                if showsBanner, let message = model.snapshot.message {
                    banner(message)
                }
                if showsLicenseBanner, let message = licenseBanner {
                    banner(message)
                }
                main
            }
            .navigationTitle("umbilical")
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
        }
        .frame(minWidth: 680, minHeight: 420)
        .sheet(isPresented: $showingAdd) {
            AddDownloadSheet(model: model)
        }
        .sheet(item: stagedHandoff) { staged in
            HandoffConfirmSheet(model: model, staged: staged)
        }
    }

    private var stagedHandoff: Binding<StagedHandoff?> {
        Binding(
            get: { model.stagedHandoff },
            set: { value in
                if value == nil {
                    model.declineStagedHandoff()
                }
            }
        )
    }

    private var subtitle: String {
        guard let path = model.snapshot.downloadDirectoryPath else {
            return "Choose a download folder"
        }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private var showsBanner: Bool {
        guard let message = model.snapshot.message, !message.isEmpty else {
            return false
        }
        if model.snapshot.rows.isEmpty {
            return false
        }
        return true
    }

    @ViewBuilder
    private var main: some View {
        if model.snapshot.rows.isEmpty {
            empty
        } else {
            DownloadList(model: model)
        }
    }

    @ViewBuilder
    private var empty: some View {
        switch model.snapshot.phase {
        case .needsFolder:
            needsFolder
        case .starting:
            ProgressView("Starting the download engine")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .running:
            noDownloads
        case .failed:
            engineStopped
        }
    }

    private var needsFolder: some View {
        ContentUnavailableView(
            label: {
                Label("Choose a download folder", systemImage: "folder")
            },
            description: {
                Text("umbilical only saves files inside the folder you choose.")
            },
            actions: {
                Button("Choose Folder…") { chooseRoot() }
            }
        )
    }

    private var noDownloads: some View {
        ContentUnavailableView(
            label: {
                Label("No downloads", systemImage: "arrow.down.circle")
            },
            description: {
                Text(emptyDownloadText)
            },
            actions: {
                Button("Add Download") { showingAdd = true }
                    .disabled(!canStartDownload)
            }
        )
    }

    private var engineStopped: some View {
        ContentUnavailableView(
            label: {
                Label("Engine stopped", systemImage: "exclamationmark.triangle")
            },
            description: {
                Text(model.snapshot.message ?? "The download engine is not running.")
            },
            actions: {
                Button("Try Again") {
                    Task { await model.start() }
                }
                Button("Choose Folder…") { chooseRoot() }
            }
        )
    }

    private func banner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.snapshot.phase == .failed {
                Button("Try Again") {
                    Task { await model.start() }
                }
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal)
        .padding(.top, 8)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showingAdd = true
            } label: {
                Label("Add Download", systemImage: "plus")
            }
            .disabled(!canStartDownload)
            .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        ToolbarItem(placement: .automatic) {
            Button("Choose Folder…") { chooseRoot() }
        }
    }

    @ViewBuilder
    private var unofficialCaption: some View {
        if case .unofficial = model.license.status {
            Text(LicenseCopy.panel(for: model.license).statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, 8)
        }
    }

    private var licenseBanner: String? {
        LicenseCopy.banner(for: model.license.status)
    }

    private var showsLicenseBanner: Bool {
        licenseBanner != nil && !model.snapshot.rows.isEmpty
    }

    private var canStartDownload: Bool {
        model.snapshot.canAdd && model.licenseAllowsNewDownloads
    }

    private var emptyDownloadText: String {
        if let licenseBanner {
            return licenseBanner
        }
        return "Add an http or https URL. Active downloads stop when umbilical quits. "
            + "In Safari, allow website access in Safari Settings > Extensions > umbilical, "
            + "then right-click a link."
    }

    private func chooseRoot() {
        guard
            let picked = MacActions.chooseDirectory(
                startingAt: model.downloadDirectory,
                message: "umbilical saves every download inside this folder."
            )
        else { return }
        Task { _ = await model.useRoot(picked) }
    }
}
