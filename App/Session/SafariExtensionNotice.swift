// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum SafariExtensionNotice {
    public static let extensionBundleIdentifier = "me.peapod.umbilical.extension"
    public static let dismissedVersionKey = "umb.safariExtensionNoticeDismissedVersion"

    public static let message =
        "Safari turned off the umbilical extension after this update. "
        + "To turn it back on, open Safari Settings, choose Extensions, "
        + "and tick umbilical."

    public static let openPreferencesTitle = "Open Safari Settings"
    public static let dismissTitle = "Dismiss"

    /// Safari can return nil or an error when the extension is off after a
    /// permission change. Those reads count as disabled. An enabled result
    /// hides the notice.
    public static func isDisabled(_ isEnabled: Bool?) -> Bool {
        isEnabled != true
    }

    public static func shouldShow(
        isEnabled: Bool?,
        currentVersion: String,
        dismissedVersion: String?
    ) -> Bool {
        guard isDisabled(isEnabled) else { return false }
        guard !currentVersion.isEmpty else { return false }
        return dismissedVersion != currentVersion
    }
}
