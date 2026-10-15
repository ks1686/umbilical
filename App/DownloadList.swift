// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UmbilicalUI

struct DownloadList: View {
    @ObservedObject var model: AppModel

    var body: some View {
        List {
            ForEach(model.snapshot.rows) { row in
                DownloadRowView(row: row, model: model)
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

struct DownloadRowView: View {
    let row: DownloadRow
    @ObservedObject var model: AppModel
    @State private var confirmingRemove = false

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            details
            controls
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .confirmationDialog(
            "Remove this download?",
            isPresented: $confirmingRemove,
            titleVisibility: .visible,
            actions: {
                Button("Remove", role: .destructive) {
                    Task { await model.remove(id: row.id) }
                }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text("An active download stops. A finished download leaves the list.")
            }
        )
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(row.title)
                    .font(.headline)
                Spacer()
                Text(row.stateText)
                    .foregroundStyle(row.errorMessage == nil ? Color.secondary : Color.red)
                    .monospacedDigit()
            }
            Text(row.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            progress
            HStack(spacing: 12) {
                if !row.sizeText.isEmpty {
                    Text(row.sizeText)
                }
                if !row.speedText.isEmpty {
                    Text(row.speedText)
                }
                if !row.etaText.isEmpty {
                    Text(row.etaText)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            if let error = row.errorMessage, !error.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    @ViewBuilder
    private var progress: some View {
        if let fraction = row.fraction {
            ProgressView(value: fraction)
        } else if row.showsIndeterminateProgress {
            ProgressView()
        }
    }

    private var controls: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(row.canResume ? "Resume" : "Pause") {
                Task { await toggleRun() }
            }
            .disabled(!row.canPause && !row.canResume)
            Button(row.cancelsLiveVideo ? "Cancel" : "Remove") {
                if row.cancelsLiveVideo {
                    Task { await model.remove(id: row.id) }
                } else {
                    confirmingRemove = true
                }
            }
            .disabled(!row.canRemove)
            if row.isComplete, let path = row.filePath, fileExists(path) {
                Button("Show in Finder") {
                    MacActions.reveal(path)
                }
            }
        }
        .buttonStyle(.borderless)
    }

    private func toggleRun() async {
        if row.canResume {
            await model.resume(id: row.id)
        } else {
            await model.pause(id: row.id)
        }
    }

    private func fileExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
