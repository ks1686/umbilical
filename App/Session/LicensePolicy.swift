// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum LicensePolicy {
    /// Offline use after the last successful Polar check. One constant.
    public static let offlineGrace: TimeInterval = 14 * 24 * 60 * 60
    public static let recheckInterval: TimeInterval = 24 * 60 * 60
    public static let retryInterval: TimeInterval = 15 * 60
    /// A clock step smaller than this is not treated as rollback.
    public static let clockSkew: TimeInterval = 5 * 60
    public static let observationStep: TimeInterval = 60 * 60
    /// Polar enforces this. The app only explains it.
    public static let activationLimit = 3

    public static var offlineGraceDays: Int {
        Int(offlineGrace / (24 * 60 * 60))
    }
}

public struct LicenseSummary: Equatable {
    public var maskedKey: String
    public var deviceLabel: String
    public var validatedAt: Date
}

public enum LicenseDenial: Equatable {
    case missing
    case unvalidated
    case limitReached
    case notFound
    case revoked
    case disabled
    case expired
    case graceExpired
    case clockRollback
    case unreachable
    case invalidConfiguration
    case keychainFailed
    case rejected
}

public enum LicenseStatus: Equatable {
    case unofficial(String)
    case licensed(LicenseSummary)
    case offlineGrace(LicenseSummary, until: Date)
    case unlicensed(LicenseDenial)
}

public struct LicensePermissions: Equatable {
    public var allowsNewDownloads: Bool
    public var allowsResume: Bool
    /// License state never stops a download that is already running.
    public var stopsActiveDownloads: Bool

    public static func resolve(_ status: LicenseStatus) -> LicensePermissions {
        switch status {
        case .unofficial, .licensed, .offlineGrace:
            return LicensePermissions(
                allowsNewDownloads: true,
                allowsResume: true,
                stopsActiveDownloads: false
            )
        case .unlicensed:
            return LicensePermissions(
                allowsNewDownloads: false,
                allowsResume: false,
                stopsActiveDownloads: false
            )
        }
    }
}

public struct LicenseBlocked: Error, Equatable, CustomStringConvertible {
    public var message: String

    public init(message: String) {
        self.message = message
    }

    public var description: String { message }
}

public struct LicenseSnapshot: Equatable {
    public var status: LicenseStatus
    public var canDeactivate: Bool
    public var deviceLabel: String?
    public var isBusy: Bool
    public var actionError: String?

    public static let empty = LicenseSnapshot(
        status: .unlicensed(.missing),
        canDeactivate: false,
        deviceLabel: nil,
        isBusy: false,
        actionError: nil
    )
}

enum LicenseBinding {
    static func accepts(
        validation: LicenseValidationRecord,
        credential: LicenseCredential,
        deviceID: String
    ) -> Bool {
        guard credential.block == nil else { return false }
        guard !validation.key.isEmpty, !validation.activationID.isEmpty else { return false }
        guard validation.key == credential.key else { return false }
        guard validation.activationID == credential.activationID else { return false }
        return validation.deviceID == deviceID && credential.deviceID == deviceID
    }
}

enum LicenseClockCheck {
    static func isRollback(now: Date, watermark: Date) -> Bool {
        now.addingTimeInterval(LicensePolicy.clockSkew) < watermark
    }

    static func isRollback(now: Date, validation: LicenseValidationRecord) -> Bool {
        if now < validation.validatedAt { return true }
        return isRollback(now: now, watermark: validation.observedAt)
    }

    static func advance(
        _ validation: LicenseValidationRecord,
        now: Date
    ) -> LicenseValidationRecord? {
        let elapsed = now.timeIntervalSince(validation.observedAt)
        guard elapsed >= LicensePolicy.observationStep else { return nil }
        var updated = validation
        updated.observedAt = now
        return updated
    }
}
