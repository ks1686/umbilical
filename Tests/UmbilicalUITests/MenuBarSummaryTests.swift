// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

final class MenuBarSummaryTests: XCTestCase {
    func testIdleTitleIsEmpty() {
        XCTAssertEqual(MenuBarSummary.idleTitle, "")
        XCTAssertEqual(MenuBarSummary.title(for: []), "")
    }
}
