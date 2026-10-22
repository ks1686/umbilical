// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Decides whether the shared app-wide alert presenter may show a message.
public enum AppAlertGate {
    public static func shouldPresent(
        message: String,
        alreadyPresenting: Bool,
        terminating: Bool
    ) -> Bool {
        if terminating || alreadyPresenting {
            return false
        }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty
    }
}
