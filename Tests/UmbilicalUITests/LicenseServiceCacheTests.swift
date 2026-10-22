// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

final class LicenseServiceCacheTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        boundLicenseTestDuration()
    }

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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

    @MainActor
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
        XCTAssertEqual(service.snapshot.actionNotice, LicenseCopy.deactivated)
        XCTAssertNil(service.snapshot.actionError)
        let panel = LicenseCopy.panel(for: service.snapshot)
        XCTAssertEqual(panel.confirmationText, LicenseCopy.deactivated)
        XCTAssertNil(panel.errorText)
    }

    @MainActor
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

    @MainActor
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
