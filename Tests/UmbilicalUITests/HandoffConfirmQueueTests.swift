// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

final class HandoffConfirmQueueTests: XCTestCase {
    func testASecondRequestWaitsAndIsNeverDropped() {
        var queue = HandoffConfirmQueue<String>()
        queue.enqueue("metalink")
        XCTAssertEqual(queue.current, "metalink")
        XCTAssertTrue(queue.pending.isEmpty)

        queue.enqueue("torrent")
        XCTAssertEqual(queue.current, "metalink")
        XCTAssertEqual(queue.pending, ["torrent"])

        queue.clearCurrent()
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.pending, ["torrent"])

        queue.presentNextIfIdle()
        XCTAssertEqual(queue.current, "torrent")
        XCTAssertTrue(queue.pending.isEmpty)

        queue.enqueue("third")
        queue.enqueue("fourth")
        XCTAssertEqual(queue.current, "torrent")
        XCTAssertEqual(queue.pending, ["third", "fourth"])
        queue.clearCurrent()
        queue.presentNextIfIdle()
        XCTAssertEqual(queue.current, "third")
        queue.clearCurrent()
        queue.presentNextIfIdle()
        XCTAssertEqual(queue.current, "fourth")
        queue.clearCurrent()
        queue.presentNextIfIdle()
        XCTAssertNil(queue.current)
        XCTAssertTrue(queue.pending.isEmpty)
    }
}
