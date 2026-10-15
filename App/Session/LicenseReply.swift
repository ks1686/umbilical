// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct ValidationReplyInput {
    var reply: PolarReply
    var credential: LicenseCredential
    var deviceID: String
    var organizationID: String
    var existing: LicenseValidationRecord?
    var now: Date
}

struct ActivationReplyInput {
    var reply: PolarReply
    var key: String
    var deviceID: String
    var organizationID: String
    var existing: LicenseValidationRecord?
    var now: Date
}

enum LicenseReplyHandler {
    enum Outcome: Equatable {
        case granted(LicenseValidationRecord)
        case blocked(LicenseServerBlock)
        case clock(LicenseValidationRecord?)
        case unavailable
        case limitReached
        case notFound
    }

    static func validation(_ input: ValidationReplyInput) -> Outcome {
        switch PolarStatus.kind(input.reply.statusCode) {
        case .unavailable:
            return .unavailable
        case .forbidden:
            return .blocked(.rejected)
        case .notFound:
            return .notFound
        case .success:
            return grantedValidation(input)
        }
    }

    static func activation(_ input: ActivationReplyInput) -> Outcome {
        switch PolarStatus.kind(input.reply.statusCode) {
        case .unavailable:
            return .unavailable
        case .forbidden:
            return .limitReached
        case .notFound:
            return .notFound
        case .success:
            return grantedActivation(input)
        }
    }

    private static func grantedValidation(_ input: ValidationReplyInput) -> Outcome {
        guard let reading = PolarLicenseParser.read(input.reply.body) else {
            return .unavailable
        }
        guard
            matchesCredential(
                reading, credential: input.credential, organizationID: input.organizationID)
        else {
            return .blocked(.rejected)
        }
        if let block = PolarGrant.block(
            status: reading.status,
            expiresAt: reading.expiresAt,
            now: input.now
        ) {
            return .blocked(block)
        }
        return grant(
            LicenseGrantInput(
                existing: input.existing,
                now: input.now,
                serverTime: reading.serverTime,
                key: input.credential.key,
                activationID: input.credential.activationID,
                deviceID: input.deviceID
            )
        )
    }

    private static func grantedActivation(_ input: ActivationReplyInput) -> Outcome {
        guard let reading = PolarLicenseParser.read(input.reply.body) else {
            return .blocked(.rejected)
        }
        guard let activationID = reading.activationID, !activationID.isEmpty else {
            return .blocked(.rejected)
        }
        guard matchesSubmitted(reading, key: input.key, organizationID: input.organizationID) else {
            return .blocked(.rejected)
        }
        if let block = PolarGrant.block(
            status: reading.status,
            expiresAt: reading.expiresAt,
            now: input.now
        ) {
            return .blocked(block)
        }
        return grant(
            LicenseGrantInput(
                existing: input.existing,
                now: input.now,
                serverTime: reading.serverTime,
                key: input.key,
                activationID: activationID,
                deviceID: input.deviceID
            )
        )
    }

    private static func grant(_ input: LicenseGrantInput) -> Outcome {
        switch LicenseGrant.decide(input) {
        case .granted(let record):
            return .granted(record)
        case .clock(let record):
            return .clock(record)
        }
    }

    private static func matchesCredential(
        _ reading: PolarLicenseReading,
        credential: LicenseCredential,
        organizationID: String
    ) -> Bool {
        guard matchesSubmitted(reading, key: credential.key, organizationID: organizationID) else {
            return false
        }
        guard let activationID = reading.activationID else { return false }
        return activationID == credential.activationID
    }

    private static func matchesSubmitted(
        _ reading: PolarLicenseReading,
        key: String,
        organizationID: String
    ) -> Bool {
        guard let echoed = reading.key, echoed == key else { return false }
        guard let organization = reading.organizationID else { return false }
        return organization.lowercased() == organizationID.lowercased()
    }
}
