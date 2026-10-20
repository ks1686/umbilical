// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@MainActor
extension LicenseService {
    func validateOnline() async {
        guard
            let organizationID = configuration.organizationID,
            let deviceID = device.currentDeviceID(),
            let credential = store.loadCredential(),
            credential.deviceID == deviceID,
            !credential.activationID.isEmpty
        else { return }
        lastAttemptAt = hooks.clock()
        let call = PolarLicenseRequest.validate(
            key: credential.key,
            organizationID: organizationID,
            activationID: credential.activationID
        )
        do {
            let reply = try await transport.send(call)
            await handleValidation(reply, credential: credential, deviceID: deviceID)
        } catch {
            lastNetworkFailed = true
            refreshPreservingError()
        }
    }

    private func handleValidation(
        _ reply: PolarReply,
        credential: LicenseCredential,
        deviceID: String
    ) async {
        guard let organizationID = configuration.organizationID else { return }
        let outcome = LicenseReplyHandler.validation(
            ValidationReplyInput(
                reply: reply,
                credential: credential,
                deviceID: deviceID,
                organizationID: organizationID,
                existing: store.loadValidation(),
                now: hooks.clock()
            )
        )
        await applyValidation(outcome, credential: credential)
    }

    private func applyValidation(
        _ outcome: LicenseReplyHandler.Outcome,
        credential: LicenseCredential
    ) async {
        switch outcome {
        case .unavailable:
            lastNetworkFailed = true
            refreshPreservingError()
        case .notFound:
            storeBlock(.notFound, on: credential)
        case .blocked(let block):
            storeBlock(block, on: credential)
        case .limitReached:
            storeBlock(.rejected, on: credential)
        case .clock(let record):
            await saveClock(record, releaseOnFailure: false)
        case .granted(let record):
            await saveGrant(record, releaseOnFailure: false)
        }
    }

    func saveGrant(_ record: LicenseValidationRecord, releaseOnFailure: Bool) async {
        let credential = LicenseCredential(
            key: record.key,
            activationID: record.activationID,
            deviceID: record.deviceID,
            block: nil
        )
        if releaseOnFailure {
            await saveNewGrant(credential, record: record)
            return
        }
        saveExistingGrant(credential, record: record)
    }

    private func saveNewGrant(
        _ credential: LicenseCredential,
        record: LicenseValidationRecord
    ) async {
        let saved = store.saveCredential(credential) && store.saveValidation(record)
        if !saved {
            store.clearCredential()
            store.clearValidation()
            let released = await compensate(record)
            snapshot.status = .unlicensed(.keychainFailed)
            snapshot.canDeactivate = false
            snapshot.actionError =
                released ? LicenseCopy.keychainFailed : LicenseCopy.keychainFailedUnconfirmed
            snapshot.actionNotice = nil
            return
        }
        lastNetworkFailed = false
        apply(currentEvaluation(), error: nil)
    }

    private func saveExistingGrant(
        _ credential: LicenseCredential,
        record: LicenseValidationRecord
    ) {
        guard store.saveValidation(record), store.saveCredential(credential) else {
            snapshot.actionError = LicenseCopy.keychainFailed
            snapshot.actionNotice = nil
            return
        }
        lastNetworkFailed = false
        refreshPreservingError()
    }

    func saveClock(_ record: LicenseValidationRecord?, releaseOnFailure: Bool) async {
        lastNetworkFailed = false
        if let record {
            await saveGrant(record, releaseOnFailure: releaseOnFailure)
            return
        }
        refreshPreservingError()
        guard LicensePermissions.resolve(snapshot.status).allowsNewDownloads else { return }
        snapshot.status = .unlicensed(.clockRollback)
    }

    private func storeBlock(_ block: LicenseServerBlock, on credential: LicenseCredential) {
        var updated = credential
        updated.block = block
        store.clearValidation()
        if !store.saveCredential(updated) {
            store.clearCredential()
        }
        lastNetworkFailed = false
        refreshPreservingError()
    }

    private func compensate(_ record: LicenseValidationRecord) async -> Bool {
        guard let organizationID = configuration.organizationID else {
            hooks.log("license compensation failed. organization id is missing")
            return false
        }
        let call = PolarLicenseRequest.deactivate(
            key: record.key,
            organizationID: organizationID,
            activationID: record.activationID
        )
        do {
            let reply = try await transport.send(call)
            if compensationSucceeded(reply.statusCode) {
                hooks.log("license compensation succeeded. status \(reply.statusCode)")
                return true
            }
            hooks.log("license compensation failed. status \(reply.statusCode)")
            return false
        } catch {
            let name = LicenseLog.errorName(error)
            hooks.log("license compensation failed. error \(name)")
            return false
        }
    }

    private func compensationSucceeded(_ statusCode: Int) -> Bool {
        switch PolarStatus.kind(statusCode) {
        case .success, .notFound:
            return true
        case .forbidden, .unavailable:
            return false
        }
    }
}
