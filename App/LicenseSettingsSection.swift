// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import UmbilicalUI

struct LicenseSettingsSection: View {
    @ObservedObject var model: AppModel
    @State private var key = ""
    @State private var confirmingDeactivate = false

    var body: some View {
        Section("License") {
            if showsStatusLine {
                Text(panel.statusText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let errorText = panel.errorText, !errorText.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(errorText)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Dismiss") { model.clearLicenseError() }
                        .buttonStyle(.borderless)
                }
            }
            if let label = panel.deviceLabel {
                LabeledContent("This Mac", value: label)
            }
            if panel.showsKeyField {
                TextField("License key", text: $key)
                    .onChange(of: key) { _, _ in
                        model.clearLicenseError()
                    }
                Button("Activate") { activate() }
                    .disabled(activateDisabled)
            }
            if panel.showsDeactivate {
                Button("Deactivate This Mac") { confirmingDeactivate = true }
                    .disabled(model.license.isBusy)
            }
        }
        .confirmationDialog(
            "Deactivate this Mac?",
            isPresented: $confirmingDeactivate,
            titleVisibility: .visible,
            actions: {
                Button("Deactivate", role: .destructive) {
                    Task { await model.deactivateLicense() }
                }
                Button("Cancel", role: .cancel) {}
            },
            message: {
                Text(LicenseCopy.deactivateConfirm)
            }
        )
    }

    private var panel: LicensePanel {
        LicenseCopy.panel(for: model.license)
    }

    private var showsStatusLine: Bool {
        guard let errorText = panel.errorText, !errorText.isEmpty else { return true }
        return panel.statusText != errorText
    }

    private var activateDisabled: Bool {
        if model.license.isBusy { return true }
        return key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func activate() {
        let entered = key
        Task {
            let saved = await model.activateLicense(entered)
            if saved {
                key = ""
            }
        }
    }
}
