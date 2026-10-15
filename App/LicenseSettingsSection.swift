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
            Text(panel.statusText)
                .fixedSize(horizontal: false, vertical: true)
            if let errorText = panel.errorText, !errorText.isEmpty {
                Text(errorText)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let label = panel.deviceLabel {
                LabeledContent("This Mac", value: label)
            }
            if panel.showsKeyField {
                TextField("License key", text: $key)
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
