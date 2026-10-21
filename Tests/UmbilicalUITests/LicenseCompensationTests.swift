// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

final class LicenseCompensationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        boundLicenseTestDuration()
    }

    @MainActor
    func testCompensationFailureDoesNotClaimTheSeatWasFreed() async throws {
        let captured = try await activate(compensation: .success(polarReply(status: 500)))
        XCTAssertEqual(licenseDenial(captured.service.snapshot.status), .keychainFailed)
        XCTAssertEqual(
            captured.service.snapshot.actionError,
            LicenseCopy.keychainFailedUnconfirmed
        )
        XCTAssertFalse(captured.service.snapshot.canDeactivate)
        XCTAssertNil(captured.store.credential)
        XCTAssertNil(captured.store.validation)
        XCTAssertEqual(captured.lines, ["license compensation failed. status 500"])
        assertDeactivateWasAttempted(captured.transport)
        assertVisibleCopyDoesNotClaimTheSeatWasFreed(captured.service)
        assertLogOmitsLicenseSecrets(captured.lines)
    }

    @MainActor
    func testCompensationSuccessLogsStatusWithoutTheLicenseKey() async throws {
        for status in [204, 404] {
            let captured = try await activate(compensation: .success(polarReply(status: status)))
            XCTAssertEqual(captured.service.snapshot.actionError, LicenseCopy.keychainFailed)
            XCTAssertEqual(
                captured.lines,
                ["license compensation succeeded. status \(status)"]
            )
            assertDeactivateWasAttempted(captured.transport)
            assertVisibleCopyDoesNotClaimTheSeatWasFreed(captured.service)
            assertLogOmitsLicenseSecrets(captured.lines)
        }
    }

    @MainActor
    func testCompensationErrorLogsTheTypeWithoutTheLicenseKey() async throws {
        let captured = try await activate(compensation: .failure(LicenseSecretLeakError()))
        XCTAssertEqual(
            captured.service.snapshot.actionError,
            LicenseCopy.keychainFailedUnconfirmed
        )
        XCTAssertFalse(captured.service.snapshot.canDeactivate)
        let line = try XCTUnwrap(captured.lines.first)
        XCTAssertEqual(captured.lines.count, 1)
        XCTAssertTrue(line.hasPrefix("license compensation failed. error "))
        XCTAssertTrue(line.contains("LicenseSecretLeakError"))
        assertDeactivateWasAttempted(captured.transport)
        assertVisibleCopyDoesNotClaimTheSeatWasFreed(captured.service)
        assertLogOmitsLicenseSecrets(captured.lines)
    }

    @MainActor
    private func activate(
        compensation: Result<PolarReply, Error>
    ) async throws -> CapturedCompensation {
        let store = MemoryLicenseStore()
        store.failCredentialSave = true
        let transport = StubLicenseTransport([
            .success(polarReply(status: 200, body: try LicenseFixture.activationData())),
            compensation
        ])
        let log = LicenseLogCapture()
        let service = makeLicenseService(
            store: store,
            transport: transport,
            clock: ManualClock(now),
            log: { log.record($0) }
        )
        await service.activate(LicenseFixture.key)
        return CapturedCompensation(
            service: service,
            store: store,
            transport: transport,
            lines: log.lines
        )
    }

    private func assertDeactivateWasAttempted(_ transport: StubLicenseTransport) {
        XCTAssertEqual(
            transport.calls.map(\.path),
            [PolarLicenseEndpoint.activate.rawValue, PolarLicenseEndpoint.deactivate.rawValue]
        )
    }

    @MainActor
    private func assertVisibleCopyDoesNotClaimTheSeatWasFreed(_ service: LicenseService) {
        let panel = LicenseCopy.panel(for: service.snapshot)
        XCTAssertFalse(panel.showsDeactivate)
        XCTAssertNil(service.snapshot.actionNotice)
        XCTAssertNil(panel.confirmationText)
        XCTAssertFalse(claimsSeatFreed(panel.statusText))
        XCTAssertFalse(claimsSeatFreed(panel.errorText ?? ""))
        XCTAssertFalse(claimsSeatFreed(panel.confirmationText ?? ""))
        XCTAssertNotEqual(panel.confirmationText, LicenseCopy.deactivated)
    }

    private func assertLogOmitsLicenseSecrets(_ lines: [String]) {
        XCTAssertFalse(claimsLicenseSecrets(lines.joined(separator: "\n")))
    }

    private func claimsSeatFreed(_ text: String) -> Bool {
        text.contains("freed") || text.contains("frees")
    }

    private func claimsLicenseSecrets(_ text: String) -> Bool {
        text.contains(LicenseFixture.key) || text.contains(LicenseFixture.activationID)
    }
}

private struct CapturedCompensation {
    var service: LicenseService
    var store: MemoryLicenseStore
    var transport: StubLicenseTransport
    var lines: [String]
}

private struct LicenseSecretLeakError: Error, LocalizedError {
    var errorDescription: String? {
        LicenseFixture.key + " " + LicenseFixture.activationID
    }
}

private final class LicenseLogCapture {
    private(set) var lines: [String] = []

    func record(_ line: String) {
        lines.append(line)
    }
}
