// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import UmbilicalEngine
import XCTest

@testable import UmbilicalUI

final class ByteFormatTests: XCTestCase {
    func testSizesUseBinaryUnits() {
        XCTAssertEqual(ByteFormat.size(0), "0 B")
        XCTAssertEqual(ByteFormat.size(-4), "0 B")
        XCTAssertEqual(ByteFormat.size(1000), "1000 B")
        XCTAssertEqual(ByteFormat.size(1024), "1.0 KB")
        XCTAssertEqual(ByteFormat.size(1536), "1.5 KB")
        XCTAssertEqual(ByteFormat.size(1_048_576), "1.0 MB")
    }

    func testSpeedAppendsPerSecond() {
        XCTAssertEqual(ByteFormat.speed(0), "0 B/s")
        XCTAssertEqual(ByteFormat.speed(2048), "2.0 KB/s")
    }

    func testPercentClampsAndRounds() {
        XCTAssertEqual(ByteFormat.percent(0), "0%")
        XCTAssertEqual(ByteFormat.percent(0.426), "43%")
        XCTAssertEqual(ByteFormat.percent(1), "100%")
        XCTAssertEqual(ByteFormat.percent(4), "100%")
        XCTAssertEqual(ByteFormat.percent(.nan), "0%")
    }

    func testFractionAndRemainingTime() {
        XCTAssertNil(ByteFormat.fraction(completed: 1, total: 0, state: .active))
        XCTAssertEqual(ByteFormat.fraction(completed: 0, total: 0, state: .complete), 1)
        XCTAssertEqual(ByteFormat.fraction(completed: 1024, total: 2048, state: .active), 0.5)
        XCTAssertEqual(ByteFormat.fraction(completed: 3000, total: 2048, state: .active), 1)
        XCTAssertNil(ByteFormat.remainingSeconds(completed: 0, total: 100, speed: 0))
        XCTAssertNil(ByteFormat.remainingSeconds(completed: 0, total: 0, speed: 10))
        XCTAssertEqual(ByteFormat.remainingSeconds(completed: 1024, total: 2048, speed: 1024), 1)
    }

    func testETAWords() {
        XCTAssertEqual(ByteFormat.eta(nil), "")
        XCTAssertEqual(ByteFormat.eta(-1), "")
        XCTAssertEqual(ByteFormat.eta(0), "0s")
        XCTAssertEqual(ByteFormat.eta(45), "45s")
        XCTAssertEqual(ByteFormat.eta(90), "1m 30s")
        XCTAssertEqual(ByteFormat.eta(3600), "1h 00m")
        XCTAssertEqual(ByteFormat.eta(3661), "1h 01m")
        XCTAssertFalse(ByteFormat.eta(nil).contains("\u{2014}"))
    }
}
