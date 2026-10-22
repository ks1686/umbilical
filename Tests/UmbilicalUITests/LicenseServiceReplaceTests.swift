// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

final class LicenseServiceReplaceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        boundLicenseTestDuration()
    }

    @MainActor
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
        XCTAssertNil(service.snapshot.actionNotice)
        XCTAssertNil(LicenseCopy.panel(for: service.snapshot).confirmationText)
        XCTAssertFalse(LicensePermissions.resolve(service.snapshot.status).allowsNewDownloads)
    }

    @MainActor
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

    @MainActor
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

    @MainActor
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
