// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct LicenseRuntime {
    public var configuration: LicenseConfiguration
    public var store: any LicenseStoring
    public var transport: any LicenseTransport
    public var device: any LicenseDeviceIdentifying

    public init(
        configuration: LicenseConfiguration,
        store: any LicenseStoring,
        transport: any LicenseTransport,
        device: any LicenseDeviceIdentifying
    ) {
        self.configuration = configuration
        self.store = store
        self.transport = transport
        self.device = device
    }
}

public struct LicenseHooks {
    public var clock: @MainActor () -> Date
    public var makeLabel: @MainActor () -> String
    var log: @MainActor (String) -> Void

    public init(
        clock: @escaping @MainActor () -> Date = { Date() },
        makeLabel: @escaping @MainActor () -> String = { LicenseDeviceLabel.make() }
    ) {
        self.init(clock: clock, makeLabel: makeLabel, log: { LicenseLog.write($0) })
    }

    init(
        clock: @escaping @MainActor () -> Date,
        makeLabel: @escaping @MainActor () -> String,
        log: @escaping @MainActor (String) -> Void
    ) {
        self.clock = clock
        self.makeLabel = makeLabel
        self.log = log
    }
}

@MainActor
public final class LicenseService {
    public internal(set) var snapshot: LicenseSnapshot

    let configuration: LicenseConfiguration
    let store: any LicenseStoring
    let transport: any LicenseTransport
    let device: any LicenseDeviceIdentifying
    let hooks: LicenseHooks
    var busy = false
    var lastNetworkFailed = false
    var lastAttemptAt: Date?

    public init(runtime: LicenseRuntime, hooks: LicenseHooks = LicenseHooks()) {
        configuration = runtime.configuration
        store = runtime.store
        transport = runtime.transport
        device = runtime.device
        self.hooks = hooks
        snapshot = .empty
        snapshot = makeSnapshot(error: nil)
    }

    public func launch() async {
        await reload(forceNetwork: true, clearError: true)
    }

    public func tick() async {
        guard !busy else { return }
        await reload(forceNetwork: false, clearError: false)
    }

    /// Drops the Activate or Deactivate message and shows the stored license again.
    public func clearActionError() {
        guard snapshot.actionError != nil || snapshot.actionNotice != nil else { return }
        apply(currentEvaluation(), error: nil)
    }

    public func activate(_ rawKey: String) async {
        guard !busy else { return }
        guard configuration.enforcement == .on, configuration.organizationID != nil else { return }
        clearActionError()
        guard let key = LicenseKeyNormalize.normalize(rawKey) else {
            snapshot.actionError = LicenseCopy.enterKey
            return
        }
        guard let deviceID = device.currentDeviceID() else {
            snapshot.status = .unlicensed(.unvalidated)
            snapshot.actionError = nil
            return
        }
        if await reused(key: key, deviceID: deviceID) { return }
        guard let organizationID = configuration.organizationID, let label = ensureLabel() else {
            snapshot.actionError = LicenseCopy.keychainFailed
            return
        }
        await performActivate(
            key: key,
            deviceID: deviceID,
            organizationID: organizationID,
            label: label
        )
    }

    public func deactivate() async {
        guard !busy, configuration.enforcement == .on else { return }
        clearActionError()
        guard let deviceID = device.currentDeviceID(), let credential = store.loadCredential()
        else {
            apply(currentEvaluation(), error: nil)
            return
        }
        guard credential.deviceID == deviceID else {
            store.clearCredential()
            store.clearValidation()
            apply(currentEvaluation(), error: nil)
            return
        }
        await finishDeactivate(credential)
    }

    private func reload(forceNetwork: Bool, clearError: Bool) async {
        guard configuration.enforcement == .on else {
            snapshot = makeSnapshot(error: nil)
            return
        }
        advanceObservation()
        let evaluation = currentEvaluation()
        let error = clearError ? nil : snapshot.actionError
        let notice = clearError ? nil : snapshot.actionNotice
        apply(evaluation, error: error, notice: notice)
        guard evaluation.allowNetworkValidate else { return }
        guard forceNetwork || networkDue() else { return }
        await validateOnline()
    }

    private func advanceObservation() {
        guard
            let deviceID = device.currentDeviceID(),
            let credential = store.loadCredential(),
            let validation = store.loadValidation(),
            LicenseBinding.accepts(
                validation: validation,
                credential: credential,
                deviceID: deviceID
            )
        else { return }
        let now = hooks.clock()
        guard !LicenseClockCheck.isRollback(now: now, validation: validation) else { return }
        guard let updated = LicenseClockCheck.advance(validation, now: now) else { return }
        _ = store.saveValidation(updated)
    }

    private func networkDue() -> Bool {
        guard let lastAttemptAt else { return true }
        let wait = lastNetworkFailed ? LicensePolicy.retryInterval : LicensePolicy.recheckInterval
        return hooks.clock().timeIntervalSince(lastAttemptAt) >= wait
    }

    func currentEvaluation() -> LicenseEvaluation {
        LicenseEvaluator.evaluate(
            LicenseLocalInput(
                credential: store.loadCredential(),
                validation: store.loadValidation(),
                deviceID: device.currentDeviceID(),
                label: store.loadLabel(),
                now: hooks.clock(),
                networkFailed: lastNetworkFailed
            )
        )
    }

    func refreshPreservingError() {
        apply(
            currentEvaluation(),
            error: snapshot.actionError,
            notice: snapshot.actionNotice
        )
    }

    func apply(_ evaluation: LicenseEvaluation, error: String?, notice: String? = nil) {
        if evaluation.clearCredential {
            store.clearCredential()
        }
        if evaluation.clearValidation {
            store.clearValidation()
        }
        snapshot = LicenseSnapshot(
            status: evaluation.status,
            canDeactivate: canDeactivateNow(),
            deviceLabel: displayLabel(),
            isBusy: busy,
            actionError: error,
            actionNotice: notice
        )
    }

    private func makeSnapshot(error: String?, notice: String? = nil) -> LicenseSnapshot {
        switch configuration.enforcement {
        case .off:
            return LicenseSnapshot(
                status: .unofficial(configuration.unofficialNote),
                canDeactivate: false,
                deviceLabel: nil,
                isBusy: busy,
                actionError: error,
                actionNotice: notice
            )
        case .invalidOrganizationID:
            return LicenseSnapshot(
                status: .unlicensed(.invalidConfiguration),
                canDeactivate: false,
                deviceLabel: nil,
                isBusy: busy,
                actionError: error,
                actionNotice: notice
            )
        case .on:
            let evaluation = currentEvaluation()
            return LicenseSnapshot(
                status: evaluation.status,
                canDeactivate: canDeactivateNow(),
                deviceLabel: displayLabel(),
                isBusy: busy,
                actionError: error,
                actionNotice: notice
            )
        }
    }

    private func canDeactivateNow() -> Bool {
        guard let deviceID = device.currentDeviceID(), let credential = store.loadCredential()
        else {
            return false
        }
        guard credential.deviceID == deviceID else { return false }
        return !credential.key.isEmpty && !credential.activationID.isEmpty
    }

    private func displayLabel() -> String? {
        guard let label = store.loadLabel(), !label.isEmpty else { return nil }
        return label
    }

    private func ensureLabel() -> String? {
        if let label = store.loadLabel(), !label.isEmpty { return label }
        let created = hooks.makeLabel()
        guard store.saveLabel(created) else { return nil }
        return created
    }
}
