// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import SafariServices
import UmbilicalUI

enum SafariExtensionBridge {
    static func refresh(_ notice: SafariExtensionNoticeController) {
        SFSafariExtensionManager.getStateOfSafariExtension(
            withIdentifier: SafariExtensionNotice.extensionBundleIdentifier
        ) { state, error in
            let enabled: Bool?
            if error != nil {
                enabled = nil
            } else {
                enabled = state?.isEnabled
            }
            Task { @MainActor in
                notice.apply(isEnabled: enabled)
            }
        }
    }

    static func showPreferences() {
        SFSafariApplication.showPreferencesForExtension(
            withIdentifier: SafariExtensionNotice.extensionBundleIdentifier
        )
    }
}
