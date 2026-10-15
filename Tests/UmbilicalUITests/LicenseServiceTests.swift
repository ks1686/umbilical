// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

@MainActor
final class LicenseServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testActivateStoresKeyActivationAndThisDevice() async throws {
        let store = MemoryLicenseStore()
        let transport = StubLicenseTransport([
            .success(polarReply(status: 200, body: try LicenseFixture.activationData()))
        ])
        let service = makeLicenseService(
            store: store, transport: transport, clock: ManualClock(now))
        await service.activate("  \(LicenseFixture.key)  ")
        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.path, PolarLicenseEndpoint.activate.rawValue)
        let body = try licenseJSON(call.body)
        XCTAssertEqual(Set(body.keys), ["key", "label", "organization_id"])
        XCTAssertEqual(body["key"] as? String, LicenseFixture.key)
        XCTAssertEqual(body["label"] as? String, LicenseFixture.label)
        XCTAssertEqual(body["organization_id"] as? String, LicenseFixture.organizationID)
        let text = String(decoding: call.body, as: UTF8.self)
        XCTAssertFalse(text.contains(LicenseFixture.deviceID))
        XCTAssertFalse(text.contains("increment_usage"))
        XCTAssertFalse(text.lowercased().contains("token"))
        XCTAssertEqual(store.credential?.key, LicenseFixture.key)
        XCTAssertEqual(store.credential?.activationID, LicenseFixture.activationID)
        XCTAssertEqual(store.credential?.deviceID, LicenseFixture.deviceID)
        XCTAssertEqual(store.validation?.key, LicenseFixture.key)
        XCTAssertEqual(store.validation?.activationID, LicenseFixture.activationID)
        XCTAssertEqual(store.validation?.deviceID, LicenseFixture.deviceID)
        XCTAssertEqual(store.validation?.validatedAt, now)
        if case .licensed = service.snapshot.status {
        } else {
            XCTFail("expected a licensed Mac")
        }
        XCTAssertTrue(LicensePermissions.resolve(service.snapshot.status).allowsNewDownloads)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).stopsActiveDownloads)
    }

    func testActivationLimitSaysHowManyMacs() async throws {
        let store = MemoryLicenseStore()
        let transport = StubLicenseTransport([
            .success(polarReply(status: 403, body: Data("{\"error\":\"NotPermitted\"}".utf8)))
        ])
        let service = makeLicenseService(
            store: store, transport: transport, clock: ManualClock(now))
        await service.activate(LicenseFixture.key)
        XCTAssertEqual(licenseDenial(service.snapshot.status), .limitReached)
        XCTAssertNil(store.credential)
        let message = LicenseCopy.denialText(.limitReached)
        XCTAssertTrue(message.contains(String(LicensePolicy.activationLimit)))
        XCTAssertTrue(message.contains("Macs"))
        XCTAssertEqual(LicenseCopy.panel(for: service.snapshot).statusText, message)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).allowsNewDownloads)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).stopsActiveDownloads)
    }

    func testValidateRefreshesTheSameActivation() async throws {
        let store = MemoryLicenseStore()
        let checked = now.addingTimeInterval(-3_600)
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: checked)
        let transport = StubLicenseTransport([
            .success(
                polarReply(status: 200, body: try LicenseFixture.validationData(status: "granted")))
        ])
        let service = makeLicenseService(
            store: store, transport: transport, clock: ManualClock(now))
        await service.launch()
        let call = try XCTUnwrap(transport.calls.first)
        XCTAssertEqual(call.path, PolarLicenseEndpoint.validate.rawValue)
        let body = try licenseJSON(call.body)
        XCTAssertEqual(
            Set(body.keys),
            ["activation_id", "key", "organization_id"]
        )
        XCTAssertEqual(store.validation?.validatedAt, now)
        XCTAssertNil(store.credential?.block)
        if case .licensed = service.snapshot.status {
        } else {
            XCTFail("expected a licensed Mac")
        }
    }

    func testDifferentKeyDeactivatesBeforeUsingAnotherSlot() async throws {
        let store = MemoryLicenseStore()
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: now)
        let transport = StubLicenseTransport([
            .success(polarReply(status: 204)),
            .success(polarReply(status: 403, body: Data("{\"error\":\"NotPermitted\"}".utf8)))
        ])
        let service = makeLicenseService(
            store: store, transport: transport, clock: ManualClock(now))
        await service.activate(LicenseFixture.otherKey)
        XCTAssertEqual(
            transport.calls.map(\.path),
            [PolarLicenseEndpoint.deactivate.rawValue, PolarLicenseEndpoint.activate.rawValue]
        )
        XCTAssertEqual(licenseDenial(service.snapshot.status), .limitReached)
        XCTAssertNil(store.credential)
        XCTAssertNil(store.validation)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).allowsNewDownloads)
    }

    func testDifferentKeyStaysPutWhenDeactivateFails() async {
        let store = MemoryLicenseStore()
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: now)
        let transport = StubLicenseTransport([.success(polarReply(status: 500))])
        let service = makeLicenseService(
            store: store, transport: transport, clock: ManualClock(now))
        await service.activate(LicenseFixture.otherKey)
        XCTAssertEqual(transport.calls.map(\.path), [PolarLicenseEndpoint.deactivate.rawValue])
        XCTAssertEqual(store.credential?.key, LicenseFixture.key)
        XCTAssertEqual(service.snapshot.actionError, LicenseCopy.replaceNeedsDeactivate)
        if case .licensed = service.snapshot.status {
        } else {
            XCTFail("expected the current license to stay")
        }
    }

    func testSameKeyValidatesInsteadOfActivatingAgain() async throws {
        let store = MemoryLicenseStore()
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: now.addingTimeInterval(-10))
        let transport = StubLicenseTransport([
            .success(
                polarReply(status: 200, body: try LicenseFixture.validationData(status: "granted")))
        ])
        let service = makeLicenseService(
            store: store, transport: transport, clock: ManualClock(now))
        await service.activate(LicenseFixture.key)
        XCTAssertEqual(transport.calls.map(\.path), [PolarLicenseEndpoint.validate.rawValue])
    }

    func testRevokedClearsGraceAndStaysRevokedOffline() async throws {
        let store = MemoryLicenseStore()
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: now.addingTimeInterval(-3_600))
        let transport = StubLicenseTransport([
            .success(
                polarReply(status: 200, body: try LicenseFixture.validationData(status: "revoked")))
        ])
        let clock = ManualClock(now)
        let service = makeLicenseService(store: store, transport: transport, clock: clock)
        await service.launch()
        XCTAssertEqual(licenseDenial(service.snapshot.status), .revoked)
        XCTAssertNil(store.validation)
        XCTAssertEqual(store.credential?.block, .revoked)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).stopsActiveDownloads)
        transport.results = [.failure(StubLicenseError())]
        clock.now = now.addingTimeInterval(LicensePolicy.retryInterval)
        await service.launch()
        XCTAssertEqual(licenseDenial(service.snapshot.status), .revoked)
        XCTAssertNotEqual(licenseDenial(service.snapshot.status), .graceExpired)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).allowsNewDownloads)
    }

    func testOfflineWithinGraceKeepsFullUse() async {
        let store = MemoryLicenseStore()
        let checked = now.addingTimeInterval(-2 * 24 * 60 * 60)
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: checked)
        let transport = StubLicenseTransport([.failure(StubLicenseError())])
        let service = makeLicenseService(
            store: store, transport: transport, clock: ManualClock(now))
        XCTAssertTrue(LicensePermissions.resolve(service.snapshot.status).allowsNewDownloads)
        await service.launch()
        guard case .offlineGrace(let summary, let until) = service.snapshot.status else {
            return XCTFail("expected offline grace")
        }
        XCTAssertEqual(summary.validatedAt, checked)
        XCTAssertEqual(until, checked.addingTimeInterval(LicensePolicy.offlineGrace))
        let permissions = LicensePermissions.resolve(service.snapshot.status)
        XCTAssertTrue(permissions.allowsNewDownloads)
        XCTAssertTrue(permissions.allowsResume)
        XCTAssertFalse(permissions.stopsActiveDownloads)
    }

    func testOfflineAfterGraceBlocksNewWorkOnly() async {
        let store = MemoryLicenseStore()
        let checked = now.addingTimeInterval(-(LicensePolicy.offlineGrace + 1))
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: checked)
        let transport = StubLicenseTransport([.failure(StubLicenseError())])
        let service = makeLicenseService(
            store: store, transport: transport, clock: ManualClock(now))
        await service.launch()
        XCTAssertEqual(licenseDenial(service.snapshot.status), .graceExpired)
        let permissions = LicensePermissions.resolve(service.snapshot.status)
        XCTAssertFalse(permissions.allowsNewDownloads)
        XCTAssertFalse(permissions.allowsResume)
        XCTAssertFalse(permissions.stopsActiveDownloads)
        XCTAssertTrue(LicenseCopy.denialText(.graceExpired).contains(LicenseCopy.runningKeepGoing))
        XCTAssertTrue(LicenseCopy.graceExpired.contains(String(LicensePolicy.offlineGraceDays)))
    }

    func testGraceAllowsTheExactDeadline() async {
        let store = MemoryLicenseStore()
        let checked = now.addingTimeInterval(-LicensePolicy.offlineGrace)
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: checked)
        let transport = StubLicenseTransport([.failure(StubLicenseError())])
        let service = makeLicenseService(
            store: store, transport: transport, clock: ManualClock(now))
        await service.launch()
        if case .offlineGrace = service.snapshot.status {
        } else {
            XCTFail("expected grace through the exact deadline")
        }
    }

    func testClockRollbackDoesNotExtendGrace() async throws {
        let store = MemoryLicenseStore()
        let checked = now.addingTimeInterval(-20 * 24 * 60 * 60)
        let observed = now.addingTimeInterval(-60)
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(
            validatedAt: checked,
            observedAt: observed
        )
        let transport = StubLicenseTransport([.failure(StubLicenseError())])
        let rolled = observed.addingTimeInterval(-(LicensePolicy.clockSkew + 60))
        let service = makeLicenseService(
            store: store,
            transport: transport,
            clock: ManualClock(rolled)
        )
        await service.launch()
        XCTAssertEqual(licenseDenial(service.snapshot.status), .clockRollback)
        XCTAssertNotEqual(licenseDenial(service.snapshot.status), .graceExpired)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).allowsNewDownloads)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).stopsActiveDownloads)
        XCTAssertEqual(store.validation?.validatedAt, checked)
    }

    func testSuccessfulCheckDoesNotMoveTheClockBackward() async throws {
        let store = MemoryLicenseStore()
        let checked = now.addingTimeInterval(-10 * 24 * 60 * 60)
        let observed = now
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: checked, observedAt: observed)
        let body = try LicenseFixture.validationData(status: "granted")
        let transport = StubLicenseTransport([.success(polarReply(status: 200, body: body))])
        let rolled = now.addingTimeInterval(-(LicensePolicy.clockSkew + 3_600))
        let service = makeLicenseService(
            store: store,
            transport: transport,
            clock: ManualClock(rolled)
        )
        await service.launch()
        XCTAssertEqual(licenseDenial(service.snapshot.status), .clockRollback)
        XCTAssertEqual(store.validation?.validatedAt, checked)
        XCTAssertEqual(store.validation?.observedAt, observed)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).allowsNewDownloads)
    }

    func testRecordCopiedFromAnotherDeviceIsUnvalidated() async {
        let store = MemoryLicenseStore()
        let checked = now.addingTimeInterval(-3_600)
        store.credential = LicenseFixture.credential(deviceID: LicenseFixture.otherDeviceID)
        store.validation = LicenseFixture.validation(
            deviceID: LicenseFixture.otherDeviceID,
            validatedAt: checked
        )
        let transport = StubLicenseTransport([
            .success(polarReply(status: 200, body: Data("nope".utf8)))
        ])
        let service = makeLicenseService(
            store: store, transport: transport, clock: ManualClock(now))
        await service.launch()
        XCTAssertEqual(licenseDenial(service.snapshot.status), .unvalidated)
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertNil(store.credential)
        XCTAssertNil(store.validation)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).allowsNewDownloads)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).stopsActiveDownloads)
        await service.deactivate()
        XCTAssertTrue(transport.calls.isEmpty)
    }

    func testKeyMismatchIsUnvalidated() async {
        let store = MemoryLicenseStore()
        let checked = now.addingTimeInterval(-3_600)
        store.credential = LicenseFixture.credential(key: LicenseFixture.otherKey)
        store.validation = LicenseFixture.validation(key: LicenseFixture.key, validatedAt: checked)
        let transport = StubLicenseTransport([
            .success(polarReply(status: 200, body: Data("nope".utf8)))
        ])
        let service = makeLicenseService(
            store: store, transport: transport, clock: ManualClock(now))
        await service.launch()
        XCTAssertEqual(licenseDenial(service.snapshot.status), .unvalidated)
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertNil(store.validation)
        XCTAssertEqual(store.credential?.key, LicenseFixture.otherKey)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).allowsNewDownloads)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).stopsActiveDownloads)
    }

    func testMissingDeviceIDDoesNotUseOrDeleteTheCache() async {
        let store = MemoryLicenseStore()
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: now.addingTimeInterval(-60))
        let device = StubLicenseDevice(nil)
        let transport = StubLicenseTransport([
            .success(polarReply(status: 200, body: Data("nope".utf8)))
        ])
        var options = LicenseHarnessOptions()
        options.device = device
        let service = makeLicenseService(
            store: store,
            transport: transport,
            clock: ManualClock(now),
            options: options
        )
        await service.launch()
        XCTAssertEqual(licenseDenial(service.snapshot.status), .unvalidated)
        XCTAssertTrue(transport.calls.isEmpty)
        XCTAssertNotNil(store.credential)
        XCTAssertNotNil(store.validation)
    }

    func testDeactivateFreesTheLocalRecord() async throws {
        let store = MemoryLicenseStore()
        store.label = LicenseFixture.label
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: now)
        let transport = StubLicenseTransport([.success(polarReply(status: 204))])
        let service = makeLicenseService(
            store: store, transport: transport, clock: ManualClock(now))
        await service.deactivate()
        XCTAssertEqual(transport.calls.map(\.path), [PolarLicenseEndpoint.deactivate.rawValue])
        let body = try licenseJSON(XCTUnwrap(transport.calls.first).body)
        XCTAssertEqual(Set(body.keys), ["activation_id", "key", "organization_id"])
        XCTAssertNil(store.credential)
        XCTAssertNil(store.validation)
        XCTAssertEqual(store.label, LicenseFixture.label)
        XCTAssertEqual(licenseDenial(service.snapshot.status), .missing)
    }

    func testUnofficialBuildDoesNotCallPolar() async {
        let transport = StubLicenseTransport([
            .success(polarReply(status: 200, body: Data("nope".utf8)))
        ])
        var options = LicenseHarnessOptions()
        options.enforcement = .off
        let service = makeLicenseService(
            transport: transport,
            clock: ManualClock(now),
            options: options
        )
        await service.launch()
        await service.activate(LicenseFixture.key)
        XCTAssertTrue(transport.calls.isEmpty)
        guard case .unofficial(let note) = service.snapshot.status else {
            return XCTFail("expected an unofficial build")
        }
        XCTAssertTrue(note.contains("Unofficial build"))
        XCTAssertTrue(LicensePermissions.resolve(service.snapshot.status).allowsNewDownloads)
    }

    func testRecheckWaitsAndRetryIsSooner() async throws {
        let store = MemoryLicenseStore()
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: now.addingTimeInterval(-60))
        let body = try LicenseFixture.validationData(status: "granted")
        let transport = StubLicenseTransport([
            .success(polarReply(status: 200, body: body)),
            .failure(StubLicenseError()),
            .success(polarReply(status: 200, body: body))
        ])
        let clock = ManualClock(now)
        let service = makeLicenseService(store: store, transport: transport, clock: clock)
        await service.launch()
        XCTAssertEqual(transport.calls.count, 1)
        clock.now = now.addingTimeInterval(60)
        await service.tick()
        XCTAssertEqual(transport.calls.count, 1)
        clock.now = now.addingTimeInterval(LicensePolicy.recheckInterval)
        await service.tick()
        XCTAssertEqual(transport.calls.count, 2)
        clock.now = clock.now.addingTimeInterval(60)
        await service.tick()
        XCTAssertEqual(transport.calls.count, 2)
        clock.now = clock.now.addingTimeInterval(LicensePolicy.retryInterval)
        await service.tick()
        XCTAssertEqual(transport.calls.count, 3)
    }
}
