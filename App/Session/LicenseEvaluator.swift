// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct LicenseLocalInput {
    var credential: LicenseCredential?
    var validation: LicenseValidationRecord?
    var deviceID: String?
    var label: String?
    var now: Date
    var networkFailed: Bool
}

struct LicenseEvaluation: Equatable {
    var status: LicenseStatus
    var clearCredential: Bool
    var clearValidation: Bool
    var allowNetworkValidate: Bool
}

enum LicenseEvaluator {
    static func evaluate(_ input: LicenseLocalInput) -> LicenseEvaluation {
        guard let deviceID = input.deviceID else {
            return hold(.unlicensed(.unvalidated), clearValidation: false, network: false)
        }
        if let copied = copiedRecord(input, deviceID: deviceID) {
            return copied
        }
        if let blocked = serverBlock(input, deviceID: deviceID) {
            return blocked
        }
        if let mismatched = mismatchedCache(input, deviceID: deviceID) {
            return mismatched
        }
        return access(input, deviceID: deviceID)
    }

    private static func copiedRecord(
        _ input: LicenseLocalInput,
        deviceID: String
    ) -> LicenseEvaluation? {
        let credentialCopied = input.credential.map { $0.deviceID != deviceID } ?? false
        if credentialCopied {
            return LicenseEvaluation(
                status: .unlicensed(.unvalidated),
                clearCredential: true,
                clearValidation: true,
                allowNetworkValidate: false
            )
        }
        let validationCopied = input.validation.map { $0.deviceID != deviceID } ?? false
        let credentialLocal = input.credential.map { $0.deviceID == deviceID } ?? false
        guard validationCopied, !credentialLocal else { return nil }
        return LicenseEvaluation(
            status: .unlicensed(.unvalidated),
            clearCredential: false,
            clearValidation: true,
            allowNetworkValidate: false
        )
    }

    private static func serverBlock(
        _ input: LicenseLocalInput,
        deviceID: String
    ) -> LicenseEvaluation? {
        guard let credential = input.credential, credential.deviceID == deviceID else {
            return nil
        }
        guard let block = credential.block else { return nil }
        return LicenseEvaluation(
            status: .unlicensed(block.denial),
            clearCredential: false,
            clearValidation: true,
            allowNetworkValidate: true
        )
    }

    private static func mismatchedCache(
        _ input: LicenseLocalInput,
        deviceID: String
    ) -> LicenseEvaluation? {
        guard let validation = input.validation else { return nil }
        guard let credential = input.credential else {
            return LicenseEvaluation(
                status: .unlicensed(.unvalidated),
                clearCredential: false,
                clearValidation: true,
                allowNetworkValidate: false
            )
        }
        if LicenseBinding.accepts(
            validation: validation,
            credential: credential,
            deviceID: deviceID
        ) {
            return nil
        }
        return LicenseEvaluation(
            status: .unlicensed(.unvalidated),
            clearCredential: false,
            clearValidation: true,
            allowNetworkValidate: false
        )
    }

    private static func access(
        _ input: LicenseLocalInput,
        deviceID: String
    ) -> LicenseEvaluation {
        guard let credential = input.credential, credential.deviceID == deviceID else {
            return hold(
                .unlicensed(.missing), clearValidation: input.validation != nil, network: false)
        }
        guard let validation = input.validation else {
            return hold(.unlicensed(.unvalidated), clearValidation: false, network: false)
        }
        guard
            LicenseBinding.accepts(
                validation: validation,
                credential: credential,
                deviceID: deviceID
            )
        else {
            return hold(.unlicensed(.unvalidated), clearValidation: true, network: false)
        }
        if LicenseClockCheck.isRollback(now: input.now, validation: validation) {
            return hold(.unlicensed(.clockRollback), clearValidation: false, network: true)
        }
        return window(input, validation: validation)
    }

    private static func window(
        _ input: LicenseLocalInput,
        validation: LicenseValidationRecord
    ) -> LicenseEvaluation {
        let summary = LicenseSummary(
            maskedKey: LicenseKeyMask.mask(validation.key),
            deviceLabel: input.label ?? "",
            validatedAt: validation.validatedAt
        )
        let age = input.now.timeIntervalSince(validation.validatedAt)
        guard age <= LicensePolicy.offlineGrace else {
            return hold(.unlicensed(.graceExpired), clearValidation: false, network: true)
        }
        let until = validation.validatedAt.addingTimeInterval(LicensePolicy.offlineGrace)
        let status: LicenseStatus =
            input.networkFailed
            ? .offlineGrace(summary, until: until)
            : .licensed(summary)
        return hold(status, clearValidation: false, network: true)
    }

    private static func hold(
        _ status: LicenseStatus,
        clearValidation: Bool,
        network: Bool
    ) -> LicenseEvaluation {
        LicenseEvaluation(
            status: status,
            clearCredential: false,
            clearValidation: clearValidation,
            allowNetworkValidate: network
        )
    }
}

struct LicenseGrantInput {
    var existing: LicenseValidationRecord?
    var now: Date
    var serverTime: Date?
    var key: String
    var activationID: String
    var deviceID: String
}

enum LicenseGrant {
    enum Decision: Equatable {
        case granted(LicenseValidationRecord)
        case clock(LicenseValidationRecord?)
    }

    static func decide(_ input: LicenseGrantInput) -> Decision {
        if let existing = input.existing,
            LicenseClockCheck.isRollback(now: input.now, validation: existing)
        {
            return .clock(nil)
        }
        let trusted = input.serverTime ?? input.now
        if LicenseClockCheck.isRollback(now: input.now, watermark: trusted) {
            return .clock(marked(input, trusted: trusted))
        }
        let observed = max(input.existing?.observedAt ?? trusted, max(trusted, input.now))
        return .granted(record(input, validatedAt: trusted, observedAt: observed))
    }

    private static func marked(
        _ input: LicenseGrantInput,
        trusted: Date
    ) -> LicenseValidationRecord {
        record(
            input,
            validatedAt: trusted,
            observedAt: max(input.existing?.observedAt ?? trusted, trusted)
        )
    }

    private static func record(
        _ input: LicenseGrantInput,
        validatedAt: Date,
        observedAt: Date
    ) -> LicenseValidationRecord {
        LicenseValidationRecord(
            key: input.key,
            activationID: input.activationID,
            deviceID: input.deviceID,
            validatedAt: validatedAt,
            observedAt: observedAt
        )
    }
}
