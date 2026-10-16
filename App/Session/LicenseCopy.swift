// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct LicensePanel: Equatable {
    public var statusText: String
    public var errorText: String?
    public var isError: Bool
    public var deviceLabel: String?
    public var showsKeyField: Bool
    public var showsDeactivate: Bool
}

public enum LicenseCopy {
    public static let runningKeepGoing =
        "Downloads already running keep going. New downloads and resumes wait."

    public static let unofficialDebug = "Unofficial build. License checks are off."

    public static let unofficialSource =
        "Unofficial build. License checks are off. This build has no Polar organization id."

    public static let sourceBuildsWork = "Building from source does not require a license key."

    public static let notFound = "Polar did not recognize this key."
    public static let revoked = "This license was revoked."
    public static let disabled = "This license is disabled."
    public static let expired = "This license has expired."
    public static let rejected = "Polar refused this license check."
    public static let unreachable = "Could not reach Polar. Check the network and try again."
    public static let enterKey = "Enter a license key."
    public static let keychainFailed =
        "The Keychain did not save the license. "
        + "If this Mac was activated, deactivate it in the Polar customer portal and try again."
    public static let deactivateFailed =
        "Polar did not deactivate this Mac. The license on this Mac is unchanged."
    public static let missing = "Enter a license key to use umbilical on this Mac."
    public static let invalidConfiguration =
        "This release build has an invalid Polar organization id."
    public static let clockBehindPolar =
        "The Mac clock is behind Polar. Correct the clock and try again."
    public static let replaceNeedsDeactivate =
        "Deactivate this Mac before activating a different key."

    public static var limitReached: String {
        let count = LicensePolicy.activationLimit
        let noun = count == 1 ? "Mac" : "Macs"
        return "This key is already active on \(count) \(noun). "
            + "Deactivate it on another Mac, or in the Polar customer portal, then try again."
    }

    public static var unvalidated: String {
        "The saved license check does not match this Mac and this key. "
            + "Enter the key again to activate this Mac. "
            + runningKeepGoing
    }

    public static var graceExpired: String {
        "This Mac has not reached Polar in \(LicensePolicy.offlineGraceDays) days. "
            + "Connect and open umbilical to check the license. "
            + runningKeepGoing
    }

    public static let clockRollback =
        "The Mac clock is set earlier than the last time umbilical ran. "
        + "Correct the clock and check again. "
        + runningKeepGoing

    public static let actionBlocked =
        "New downloads wait until this Mac has a valid license check. "
        + runningKeepGoing

    public static let blockedEmptyState = actionBlocked

    public static let deactivateConfirm =
        "This frees one activation for this key. Downloads already running keep going."

    public static func banner(for status: LicenseStatus) -> String? {
        guard case .unlicensed(let denial) = status else { return nil }
        return denialText(denial)
    }

    public static func panel(for snapshot: LicenseSnapshot) -> LicensePanel {
        let text = statusText(snapshot.status)
        return LicensePanel(
            statusText: text,
            errorText: snapshot.actionError,
            isError: isError(snapshot.status),
            deviceLabel: snapshot.deviceLabel,
            showsKeyField: showsKeyField(snapshot.status),
            showsDeactivate: snapshot.canDeactivate
        )
    }

    public static func denialText(_ denial: LicenseDenial) -> String {
        switch denial {
        case .missing:
            return missing
        case .unvalidated:
            return unvalidated
        case .limitReached:
            return limitReached
        case .notFound:
            return notFound
        case .revoked:
            return revoked
        case .disabled:
            return disabled
        case .expired, .graceExpired, .clockRollback, .unreachable, .invalidConfiguration,
            .keychainFailed, .rejected:
            return denialTextContinued(denial)
        }
    }

    private static func statusText(_ status: LicenseStatus) -> String {
        switch status {
        case .unofficial(let note):
            return note + " " + sourceBuildsWork
        case .licensed(let summary):
            return licensed(summary)
        case .offlineGrace(let summary, let until):
            return offline(summary, until: until)
        case .unlicensed(let denial):
            return denialText(denial)
        }
    }

    private static func isError(_ status: LicenseStatus) -> Bool {
        switch status {
        case .unofficial, .licensed, .offlineGrace:
            return false
        case .unlicensed:
            return true
        }
    }

    private static func showsKeyField(_ status: LicenseStatus) -> Bool {
        switch status {
        case .unofficial, .unlicensed(.invalidConfiguration):
            return false
        case .licensed, .offlineGrace, .unlicensed:
            return true
        }
    }

    private static func licensed(_ summary: LicenseSummary) -> String {
        "Licensed (\(summary.maskedKey)). Last checked \(checked(summary.validatedAt))."
    }

    private static func offline(_ summary: LicenseSummary, until: Date) -> String {
        "Licensed offline until \(checked(until)). "
            + "The last Polar check was \(checked(summary.validatedAt))."
    }

    private static func denialTextContinued(_ denial: LicenseDenial) -> String {
        switch denial {
        case .expired:
            return expired
        case .graceExpired:
            return graceExpired
        case .clockRollback:
            return clockRollback
        case .unreachable:
            return unreachable
        case .invalidConfiguration:
            return invalidConfiguration
        case .keychainFailed:
            return keychainFailed
        case .rejected:
            return rejected
        case .missing, .unvalidated, .limitReached, .notFound, .revoked, .disabled:
            return missing
        }
    }

    private static func checked(_ date: Date) -> String {
        checkedFormatter.string(from: date)
    }

    private static let checkedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
