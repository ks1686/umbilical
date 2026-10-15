// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

final class SkeletonTests: XCTestCase {
    func testShortNameIsUmb() {
        XCTAssertEqual(UmbilicalMarker.shortName, "umb")
    }
}
