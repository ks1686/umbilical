// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UmbilicalEngine
import UmbilicalUI

struct StagedHandoff: Identifiable, Equatable {
    let id: UUID
    let handoff: ExtensionHandoff
    let source: String

    init(handoff: ExtensionHandoff, source: String, id: UUID = UUID()) {
        self.id = id
        self.handoff = handoff
        self.source = source
    }
}

struct HandoffConfirmSheet: View {
    @ObservedObject var model: AppModel
    let staged: StagedHandoff
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Download with umbilical")
                .font(.title2)
            Text(prompt)
                .fixedSize(horizontal: false, vertical: true)
            link
            if let name = staged.handoff.outputName {
                Text("Save as \(name)")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            Text("Only this URL is sent, plus the file name when one is shown.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if let reason = blockedReason {
                Text(reason)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            buttons
        }
        .padding(20)
        .frame(width: 520)
    }

    private var prompt: String {
        "\(staged.source) asked to download this link. Nothing starts until you confirm."
    }

    private var link: some View {
        Text(staged.handoff.uri)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .lineLimit(6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blockedReason: String? {
        if let handoffError = model.handoffError, !handoffError.isEmpty {
            return handoffError
        }
        if model.snapshot.canAdd {
            return nil
        }
        if model.snapshot.phase == .needsFolder {
            return "Choose a download folder first."
        }
        return model.snapshot.message
    }

    private var buttons: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) {
                model.declineStagedHandoff()
            }
            .disabled(submitting)
            Button("Download") {
                accept()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!model.snapshot.canAdd || submitting)
        }
    }

    private func accept() {
        if submitting {
            return
        }
        submitting = true
        Task {
            await model.confirmStagedHandoff()
            submitting = false
        }
    }
}
