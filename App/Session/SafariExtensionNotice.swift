// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum SafariExtensionNotice {
    public static let extensionBundleIdentifier = "me.peapod.umbilical.extension"
    public static let shownVersionKey = "umb.safariExtensionNoticeVersion"

    public static let message =
        "Safari turned off the umbilical extension after this update. "
        + "To turn it back on, open Safari Settings, choose Extensions, "
        + "and tick umbilical."

    public static let openPreferencesTitle = "Open Safari Settings"
    public static let dismissTitle = "Dismiss"

    public static func shouldShow(
        isEnabled: Bool,
        currentVersion: String,
        shownVersion: String?
    ) -> Bool {
        guard !isEnabled else { return false }
        guard !currentVersion.isEmpty else { return false }
        return shownVersion != currentVersion
    }

    public static func applied(
        isEnabled: Bool?,
        currentVersion: String,
        shownVersion: String?
    ) -> (show: Bool, shownVersion: String?) {
        guard let isEnabled else {
            return (false, shownVersion)
        }
        if shouldShow(
            isEnabled: isEnabled,
            currentVersion: currentVersion,
            shownVersion: shownVersion
        ) {
            return (true, currentVersion)
        }
        return (false, shownVersion)
    }
}
