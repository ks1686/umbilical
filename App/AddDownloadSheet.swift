// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UmbilicalUI

struct AddDownloadSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var outputName = ""
    @State private var folder: URL?
    @State private var errorText: String?
    @FocusState private var urlFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Download")
                .font(.title2)
            HStack {
                TextField("https://example.com/file", text: $urlText)
                    .textFieldStyle(.roundedBorder)
                    .focused($urlFocused)
                    .onSubmit(submit)
                Button("Paste") { pasteURL() }
            }
            TextField("Save as (optional)", text: $outputName)
                .textFieldStyle(.roundedBorder)
            HStack {
                Text(folderLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose Folder…") { chooseFolder() }
            }
            Text("The folder must stay inside the download folder.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let errorText {
                Text(errorText)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add") { submit() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { urlFocused = true }
    }

    private var folderLabel: String {
        if let folder {
            return folder.path
        }
        return model.snapshot.downloadDirectoryPath ?? "Download folder"
    }

    private func pasteURL() {
        guard let text = MacActions.clipboardText() else {
            errorText = "The clipboard has no text."
            return
        }
        urlText = text
        errorText = nil
    }

    private func chooseFolder() {
        guard
            let picked = MacActions.chooseDirectory(
                startingAt: folder ?? model.downloadDirectory,
                message: "Choose a folder inside the download folder."
            )
        else { return }
        do {
            folder = try model.checkedChildFolder(picked)
            errorText = nil
        } catch {
            errorText = DownloadMessage.text(for: error)
        }
    }

    private func submit() {
        let chosen = folder
        let url = urlText
        let name = outputName
        Task {
            do {
                try await model.add(urlText: url, outputName: name, folder: chosen)
                dismiss()
            } catch {
                errorText = DownloadMessage.text(for: error)
            }
        }
    }
}
