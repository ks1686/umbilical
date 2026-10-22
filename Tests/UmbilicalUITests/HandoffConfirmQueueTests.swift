// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

final class HandoffConfirmQueueTests: XCTestCase {
    func testASecondRequestWaitsAndIsNeverDropped() {
        var queue = HandoffConfirmQueue<String>()
        XCTAssertEqual(queue.enqueue("metalink"), .accepted)
        XCTAssertEqual(queue.current, "metalink")
        XCTAssertTrue(queue.pending.isEmpty)

        XCTAssertEqual(queue.enqueue("torrent"), .accepted)
        XCTAssertEqual(queue.current, "metalink")
        XCTAssertEqual(queue.pending, ["torrent"])

        queue.clearCurrent()
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.pending, ["torrent"])

        queue.presentNextIfIdle()
        XCTAssertEqual(queue.current, "torrent")
        XCTAssertTrue(queue.pending.isEmpty)

        XCTAssertEqual(queue.enqueue("third"), .accepted)
        XCTAssertEqual(queue.enqueue("fourth"), .accepted)
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

    func testConfirmingCurrentDoesNotApprovePending() {
        var queue = HandoffConfirmQueue<String>()
        XCTAssertEqual(queue.enqueue("first"), .accepted)
        XCTAssertEqual(queue.enqueue("second"), .accepted)
        XCTAssertEqual(queue.enqueue("third"), .accepted)
        queue.clearCurrent()
        XCTAssertNil(queue.current)
        XCTAssertEqual(queue.pending, ["second", "third"])
        queue.presentNextIfIdle()
        XCTAssertEqual(queue.current, "second")
        XCTAssertEqual(queue.pending, ["third"])
    }

    func testPendingCapRejectsTheEleventhWaitingRequest() {
        var queue = HandoffConfirmQueue<Int>()
        XCTAssertEqual(queue.enqueue(0), .accepted)
        for index in 1...HandoffConfirmQueue<Int>.pendingLimit {
            XCTAssertEqual(queue.enqueue(index), .accepted)
        }
        XCTAssertEqual(queue.current, 0)
        XCTAssertEqual(queue.pending.count, HandoffConfirmQueue<Int>.pendingLimit)
        XCTAssertEqual(queue.enqueue(99), .overflow)
        XCTAssertEqual(queue.current, 0)
        XCTAssertEqual(queue.pending.count, HandoffConfirmQueue<Int>.pendingLimit)
        XCTAssertFalse(queue.pending.contains(99))
        XCTAssertEqual(
            HandoffConfirmQueue<Int>.overflowMessage,
            "Too many downloads are waiting for confirmation. "
                + "Finish or cancel the open ones first."
        )
    }
}
