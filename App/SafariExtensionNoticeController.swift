// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI
import UmbilicalUI

@MainActor
final class SafariExtensionNoticeController: ObservableObject {
    @Published private(set) var isVisible = false

    private let currentVersion: String
    private let defaults: UserDefaults

    init(
        currentVersion: String,
        defaults: UserDefaults = .standard
    ) {
        self.currentVersion = currentVersion
        self.defaults = defaults
    }

    func apply(isEnabled: Bool?) {
        let shown = defaults.string(forKey: SafariExtensionNotice.shownVersionKey)
        let result = SafariExtensionNotice.applied(
            isEnabled: isEnabled,
            currentVersion: currentVersion,
            shownVersion: shown
        )
        guard result.show else { return }
        isVisible = true
        defaults.set(currentVersion, forKey: SafariExtensionNotice.shownVersionKey)
    }

    func dismiss() {
        isVisible = false
        defaults.set(currentVersion, forKey: SafariExtensionNotice.shownVersionKey)
    }
}
