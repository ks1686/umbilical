// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

final class RestoredWindowFilterTests: XCTestCase {
    func testOneContentWindowStays() {
        let windows = [
            RestoredWindowFilter.Snapshot(
                title: "umbilical",
                identifier: "main",
                isPanel: false,
                canBecomeMain: true
            )
        ]
        XCTAssertTrue(RestoredWindowFilter.indicesToClose(windows).isEmpty)
    }

    func testExtraContentWindowsCloseAndMainStays() {
        var windows: [RestoredWindowFilter.Snapshot] = [
            RestoredWindowFilter.Snapshot(
                title: "umbilical",
                identifier: "group-1",
                isPanel: false,
                canBecomeMain: true
            )
        ]
        for index in 2...20 {
            windows.append(
                RestoredWindowFilter.Snapshot(
                    title: "umbilical",
                    identifier: "group-\(index)",
                    isPanel: false,
                    canBecomeMain: true
                )
            )
        }
        windows.append(
            RestoredWindowFilter.Snapshot(
                title: "umbilical",
                identifier: "main",
                isPanel: false,
                canBecomeMain: true
            )
        )
        let closing = RestoredWindowFilter.indicesToClose(windows)
        XCTAssertEqual(closing.count, 20)
        XCTAssertFalse(closing.contains(20))
        XCTAssertEqual(Set(closing), Set(0...19))
    }

    func testSettingsAndPanelsStay() {
        let windows = [
            RestoredWindowFilter.Snapshot(
                title: "umbilical",
                identifier: "main",
                isPanel: false,
                canBecomeMain: true
            ),
            RestoredWindowFilter.Snapshot(
                title: "Settings",
                identifier: "settings",
                isPanel: false,
                canBecomeMain: true
            ),
            RestoredWindowFilter.Snapshot(
                title: "",
                identifier: "status",
                isPanel: true,
                canBecomeMain: false
            ),
            RestoredWindowFilter.Snapshot(
                title: "umbilical",
                identifier: "extra",
                isPanel: false,
                canBecomeMain: true
            )
        ]
        XCTAssertEqual(RestoredWindowFilter.indicesToClose(windows), [3])
    }
}
