// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalEngine
@testable import UmbilicalUI

final class DownloadRowActionTests: XCTestCase {
    func testCompletedRowHidesPauseAndResume() {
        let row = RowBuilder.make(item(state: .complete))
        XCTAssertEqual(row.stateText, "Complete")
        XCTAssertFalse(row.canPause)
        XCTAssertFalse(row.canResume)
        XCTAssertFalse(row.showsPauseResume)
    }

    func testFailedRowHidesPauseAndResume() {
        let row = RowBuilder.make(item(state: .error, errorMessage: "Failed."))
        XCTAssertEqual(row.stateText, "Failed")
        XCTAssertFalse(row.showsPauseResume)
    }

    func testCancelledRowHidesPauseAndResume() {
        let cancelled = item(
            state: .error,
            track: false,
            pausable: false,
            errorMessage: "Cancelled."
        )
        let row = RowBuilder.make(cancelled)
        XCTAssertEqual(row.errorMessage, "Cancelled.")
        XCTAssertFalse(row.cancelsLiveVideo)
        XCTAssertFalse(row.showsPauseResume)
    }

    func testRemovedRowHidesPauseAndResume() {
        let row = RowBuilder.make(item(state: .removed))
        XCTAssertFalse(row.showsPauseResume)
    }

    func testActiveRowCanPause() {
        let row = RowBuilder.make(item(state: .active))
        XCTAssertTrue(row.canPause)
        XCTAssertFalse(row.canResume)
        XCTAssertTrue(row.showsPauseResume)
    }

    func testWaitingRowCanPause() {
        let row = RowBuilder.make(item(state: .waiting))
        XCTAssertTrue(row.canPause)
        XCTAssertTrue(row.showsPauseResume)
    }

    func testPausedRowCanResume() {
        let row = RowBuilder.make(item(state: .paused))
        XCTAssertFalse(row.canPause)
        XCTAssertTrue(row.canResume)
        XCTAssertTrue(row.showsPauseResume)
    }

    func testLiveVideoRowHidesPauseAndKeepsCancel() {
        let row = RowBuilder.make(item(state: .active, pausable: false))
        XCTAssertTrue(row.cancelsLiveVideo)
        XCTAssertFalse(row.canPause)
        XCTAssertFalse(row.canResume)
        XCTAssertFalse(row.showsPauseResume)
    }

    private func item(
        state: DownloadStatus.State,
        track: Bool = true,
        pausable: Bool = true,
        errorMessage: String? = nil
    ) -> TrackedDownload {
        TrackedDownload(
            id: "g1",
            engineGID: "g1",
            track: track,
            outputName: "a.bin",
            url: URL(string: "https://example.com/a.bin"),
            detail: "https://example.com/a.bin",
            state: state,
            totalLength: 8,
            completedLength: state == .complete ? 8 : 4,
            downloadSpeed: 0,
            errorMessage: errorMessage,
            filePath: nil,
            historyID: nil,
            fixedTitle: nil,
            pausable: pausable
        )
    }
}
