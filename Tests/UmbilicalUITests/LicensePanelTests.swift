// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

final class LicensePanelTests: XCTestCase {
    func testActivateAndDeactivateButtonsHaveVoiceOverCopy() {
        XCTAssertEqual(LicensePolicy.activationLimit, 1)
        XCTAssertEqual(
            LicenseCopy.activateAccessibilityLabel,
            "Activate this license key on this Mac"
        )
        XCTAssertEqual(
            LicenseCopy.activateAccessibilityHint,
            "Checks this key with Polar. A key can be active on 1 Mac at a time."
        )
        XCTAssertEqual(
            LicenseCopy.deactivateAccessibilityLabel,
            "Deactivate this Mac and free this license seat"
        )
        XCTAssertEqual(
            LicenseCopy.deactivateAccessibilityHint,
            "This Mac's seat becomes free. A key can be active on 1 Mac at a time."
        )
        assertOmitsLicenseSecrets(LicenseCopy.activateAccessibilityLabel)
        assertOmitsLicenseSecrets(LicenseCopy.activateAccessibilityHint)
        assertOmitsLicenseSecrets(LicenseCopy.deactivateAccessibilityLabel)
        assertOmitsLicenseSecrets(LicenseCopy.deactivateAccessibilityHint)
    }

    func testDeactivatedConfirmationCopy() {
        XCTAssertEqual(LicensePolicy.activationLimit, 1)
        XCTAssertEqual(
            LicenseCopy.deactivated,
            "This license was deactivated. This Mac's seat is free."
        )
        XCTAssertFalse(LicenseCopy.deactivated.contains("freed"))
        XCTAssertFalse(LicenseCopy.deactivated.contains("frees"))
        assertOmitsLicenseSecrets(LicenseCopy.deactivated)
        let panel = LicenseCopy.panel(for: LicenseSnapshot.empty)
        XCTAssertNil(panel.confirmationText)
        XCTAssertNil(panel.errorText)
    }

    private func assertOmitsLicenseSecrets(_ text: String) {
        XCTAssertFalse(text.contains(LicenseFixture.key))
        XCTAssertFalse(text.contains(LicenseFixture.activationID))
    }
}

@MainActor
final class LicenseDeactivatePanelTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testConfirmedDeactivateShowsSeatIsFree() async throws {
        XCTAssertEqual(LicensePolicy.activationLimit, 1)
        XCTAssertEqual(
            LicenseCopy.deactivated,
            "This license was deactivated. This Mac's seat is free."
        )
        for status in [200, 204, 404] {
            let store = MemoryLicenseStore()
            store.label = LicenseFixture.label
            store.credential = LicenseFixture.credential()
            store.validation = LicenseFixture.validation(validatedAt: now)
            let transport = StubLicenseTransport([.success(polarReply(status: status))])
            let service = makeLicenseService(
                store: store, transport: transport, clock: ManualClock(now))
            await service.deactivate()
            XCTAssertEqual(service.snapshot.actionNotice, LicenseCopy.deactivated)
            XCTAssertNil(service.snapshot.actionError)
            XCTAssertEqual(licenseDenial(service.snapshot.status), .missing)
            XCTAssertFalse(service.snapshot.canDeactivate)
            let panel = LicenseCopy.panel(for: service.snapshot)
            let confirmation = try XCTUnwrap(panel.confirmationText)
            XCTAssertEqual(confirmation, LicenseCopy.deactivated)
            XCTAssertEqual(
                confirmation,
                "This license was deactivated. This Mac's seat is free."
            )
            XCTAssertNil(panel.errorText)
            XCTAssertFalse(panel.showsDeactivate)
            XCTAssertEqual(panel.statusText, LicenseCopy.missing)
            XCTAssertFalse(confirmation.contains(LicenseFixture.key))
            XCTAssertFalse(confirmation.contains(LicenseFixture.activationID))
            XCTAssertNil(store.credential)
            XCTAssertNil(store.validation)
        }
    }

    func testFailedDeactivateShowsNoConfirmation() async {
        XCTAssertEqual(
            LicenseCopy.deactivateFailed,
            "Polar did not deactivate this Mac. The license on this Mac is unchanged."
        )
        let results: [Result<PolarReply, Error>] = [
            .success(polarReply(status: 500)),
            .success(polarReply(status: 403)),
            .failure(StubLicenseError())
        ]
        for result in results {
            let store = MemoryLicenseStore()
            store.credential = LicenseFixture.credential()
            store.validation = LicenseFixture.validation(validatedAt: now)
            let transport = StubLicenseTransport([result])
            let service = makeLicenseService(
                store: store, transport: transport, clock: ManualClock(now))
            await service.deactivate()
            XCTAssertEqual(service.snapshot.actionError, LicenseCopy.deactivateFailed)
            XCTAssertNil(service.snapshot.actionNotice)
            let panel = LicenseCopy.panel(for: service.snapshot)
            XCTAssertNil(panel.confirmationText)
            XCTAssertEqual(panel.errorText, LicenseCopy.deactivateFailed)
            XCTAssertTrue(panel.showsDeactivate)
            guard case .licensed = service.snapshot.status else {
                return XCTFail("expected the current license to stay")
            }
            XCTAssertEqual(store.credential?.key, LicenseFixture.key)
            XCTAssertNotNil(store.validation)
        }
    }

    func testConfirmedDeactivateNoticeSurvivesTick() async {
        let store = MemoryLicenseStore()
        store.credential = LicenseFixture.credential()
        store.validation = LicenseFixture.validation(validatedAt: now)
        let transport = StubLicenseTransport([.success(polarReply(status: 204))])
        let clock = ManualClock(now)
        let service = makeLicenseService(store: store, transport: transport, clock: clock)
        await service.deactivate()
        XCTAssertEqual(service.snapshot.actionNotice, LicenseCopy.deactivated)
        clock.now = now.addingTimeInterval(LicensePolicy.recheckInterval)
        await service.tick()
        XCTAssertEqual(service.snapshot.actionNotice, LicenseCopy.deactivated)
        let panel = LicenseCopy.panel(for: service.snapshot)
        XCTAssertEqual(panel.confirmationText, LicenseCopy.deactivated)
        XCTAssertEqual(transport.calls.count, 1)
        service.clearActionError()
        XCTAssertNil(service.snapshot.actionNotice)
        XCTAssertNil(LicenseCopy.panel(for: service.snapshot).confirmationText)
    }
}
