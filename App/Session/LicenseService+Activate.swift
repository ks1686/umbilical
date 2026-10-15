// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@MainActor
extension LicenseService {
    func reused(key: String, deviceID: String) async -> Bool {
        guard let existing = store.loadCredential(), existing.deviceID == deviceID else {
            return false
        }
        guard !existing.activationID.isEmpty else { return false }
        if existing.key == key, existing.block != .notFound {
            await validateOnline()
            return true
        }
        guard existing.key != key else { return false }
        let removed = await requestDeactivate(existing)
        if !removed {
            snapshot.actionError = LicenseCopy.replaceNeedsDeactivate
            return true
        }
        apply(currentEvaluation(), error: nil)
        return false
    }

    func performActivate(
        key: String,
        deviceID: String,
        organizationID: String,
        label: String
    ) async {
        busy = true
        snapshot.isBusy = true
        defer {
            busy = false
            snapshot.isBusy = false
        }
        let previous = snapshot.status
        let call = PolarLicenseRequest.activate(
            key: key,
            organizationID: organizationID,
            label: label
        )
        let outcome: LicenseReplyHandler.Outcome
        do {
            let reply = try await transport.send(call)
            outcome = LicenseReplyHandler.activation(
                activationInput(
                    reply: reply,
                    key: key,
                    deviceID: deviceID,
                    organizationID: organizationID
                ))
        } catch {
            keep(previous, denial: .unreachable, error: LicenseCopy.unreachable)
            return
        }
        await finishActivation(outcome, previous: previous)
    }

    private func finishActivation(
        _ outcome: LicenseReplyHandler.Outcome,
        previous: LicenseStatus
    ) async {
        switch outcome {
        case .granted(let record):
            await saveGrant(record, releaseOnFailure: true)
        case .clock(let record):
            await saveClock(record, releaseOnFailure: true)
        case .limitReached:
            keep(previous, denial: .limitReached, error: LicenseCopy.limitReached)
        case .notFound:
            keep(previous, denial: .notFound, error: LicenseCopy.notFound)
        case .blocked(let block):
            keep(previous, denial: block.denial, error: LicenseCopy.denialText(block.denial))
        case .unavailable:
            keep(previous, denial: .unreachable, error: LicenseCopy.unreachable)
        }
    }

    func finishDeactivate(_ credential: LicenseCredential) async {
        busy = true
        snapshot.isBusy = true
        let removed = await requestDeactivate(credential)
        busy = false
        if removed {
            lastNetworkFailed = false
            apply(currentEvaluation(), error: nil)
            return
        }
        snapshot.isBusy = false
        snapshot.actionError = LicenseCopy.deactivateFailed
    }

    private func requestDeactivate(_ credential: LicenseCredential) async -> Bool {
        guard let organizationID = configuration.organizationID else { return false }
        let call = PolarLicenseRequest.deactivate(
            key: credential.key,
            organizationID: organizationID,
            activationID: credential.activationID
        )
        do {
            let reply = try await transport.send(call)
            return cleared(reply)
        } catch {
            return false
        }
    }

    private func cleared(_ reply: PolarReply) -> Bool {
        switch PolarStatus.kind(reply.statusCode) {
        case .success, .notFound:
            store.clearCredential()
            store.clearValidation()
            return true
        case .forbidden, .unavailable:
            return false
        }
    }

    private func keep(_ previous: LicenseStatus, denial: LicenseDenial, error: String) {
        if LicensePermissions.resolve(previous).allowsNewDownloads {
            snapshot.status = previous
            snapshot.actionError = error
            return
        }
        snapshot.status = .unlicensed(denial)
        snapshot.actionError = nil
    }

    private func activationInput(
        reply: PolarReply,
        key: String,
        deviceID: String,
        organizationID: String
    ) -> ActivationReplyInput {
        ActivationReplyInput(
            reply: reply,
            key: key,
            deviceID: deviceID,
            organizationID: organizationID,
            existing: store.loadValidation(),
            now: hooks.clock()
        )
    }
}
