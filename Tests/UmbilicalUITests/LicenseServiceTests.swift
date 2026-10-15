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
        let text = try XCTUnwrap(String(bytes: call.body, encoding: .utf8))
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
}
