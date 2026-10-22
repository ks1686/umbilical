// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

final class AppAlertGateTests: XCTestCase {
    func testEmptyTerminatingAndInFlightAlertsAreSkipped() {
        XCTAssertTrue(
            AppAlertGate.shouldPresent(
                message: "Download rejected",
                alreadyPresenting: false,
                terminating: false
            )
        )
        XCTAssertFalse(
            AppAlertGate.shouldPresent(
                message: "Download rejected",
                alreadyPresenting: true,
                terminating: false
            )
        )
        XCTAssertFalse(
            AppAlertGate.shouldPresent(
                message: "Download rejected",
                alreadyPresenting: false,
                terminating: true
            )
        )
        XCTAssertFalse(
            AppAlertGate.shouldPresent(
                message: "   ",
                alreadyPresenting: false,
                terminating: false
            )
        )
    }
}
