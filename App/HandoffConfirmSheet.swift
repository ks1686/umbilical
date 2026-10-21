// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UmbilicalEngine
import UmbilicalUI

struct StagedHandoff: Identifiable, Equatable {
    let id: UUID
    let handoff: ExtensionHandoff

    init(handoff: ExtensionHandoff, id: UUID = UUID()) {
        self.id = id
        self.handoff = handoff
    }
}

struct HandoffConfirmSheet: View {
    @ObservedObject var model: AppModel
    let staged: StagedHandoff
    @State private var appearedAt = Date()
    @State private var armed = false
    @State private var submitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(hostLabel)
                .font(.largeTitle)
                .textSelection(.enabled)
            Text(requestCopy)
                .fixedSize(horizontal: false, vertical: true)
            link
            if let name = staged.handoff.outputName {
                Text("Save as \(name)")
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            Text(privacyCopy)
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
        .task(id: staged.id) {
            await arm()
        }
    }

    private var hostLabel: String {
        HandoffConfirmationGate.prominentLabel(for: staged.handoff.url)
    }

    private var requestCopy: String {
        switch staged.handoff.kind {
        case .download:
            return "A download was requested. Nothing starts until you confirm."
        case .video:
            return "A video download was requested. Nothing starts until you confirm."
        case .torrentFile:
            return "A torrent file was opened. Nothing starts until you confirm. umbilical never seeds."
        case .metalinkFile:
            return "A metalink file was opened. It will be saved in your download folder. "
                + "The files it names are not started."
        }
    }

    private var privacyCopy: String {
        switch staged.handoff.kind {
        case .download, .video:
            return "Only this URL is sent, plus the file name when one is shown."
        case .torrentFile, .metalinkFile:
            return "This file stays on your Mac. It is not uploaded."
        }
    }

    private var link: some View {
        Text(staged.handoff.uri)
            .font(.body.monospaced())
            .textSelection(.enabled)
            .lineLimit(6)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blockedReason: String? {
        if !model.licenseAllowsNewDownloads {
            return LicenseCopy.actionBlocked
        }
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
                decline()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(!armed || submitting)
            Button("Download") {
                accept()
            }
            .disabled(!armed || !canDownload || submitting)
        }
    }

    private var canDownload: Bool {
        model.snapshot.canAdd && model.licenseAllowsNewDownloads
    }

    private func arm() async {
        appearedAt = Date()
        armed = false
        let nanos = UInt64(HandoffConfirmationGate.armDelay * 1_000_000_000)
        do {
            try await Task.sleep(nanoseconds: nanos)
        } catch {
            return
        }
        armed = true
    }

    private func accept() {
        let decision = HandoffConfirmationGate(appearedAt: appearedAt).decide(.download, at: Date())
        guard decision == .confirm, !submitting else {
            return
        }
        submitting = true
        Task {
            await model.confirmStagedHandoff()
            submitting = false
        }
    }

    private func decline() {
        let decision = HandoffConfirmationGate(appearedAt: appearedAt).decide(.cancel, at: Date())
        guard decision == .decline else {
            return
        }
        model.declineStagedHandoff()
    }
}
