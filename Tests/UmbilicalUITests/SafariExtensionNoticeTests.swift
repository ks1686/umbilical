// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

final class SafariExtensionNoticeTests: XCTestCase {
    func testDisabledUnknownVersionShowsOnce() {
        XCTAssertTrue(
            SafariExtensionNotice.shouldShow(
                isEnabled: false,
                currentVersion: "1.0.1",
                shownVersion: nil
            )
        )
        XCTAssertFalse(
            SafariExtensionNotice.shouldShow(
                isEnabled: false,
                currentVersion: "1.0.1",
                shownVersion: "1.0.1"
            )
        )
    }

    func testNextVersionCanShowAgain() {
        XCTAssertTrue(
            SafariExtensionNotice.shouldShow(
                isEnabled: false,
                currentVersion: "1.1.0",
                shownVersion: "1.0.1"
            )
        )
    }

    func testEnabledExtensionNeverShows() {
        XCTAssertFalse(
            SafariExtensionNotice.shouldShow(
                isEnabled: true,
                currentVersion: "1.0.1",
                shownVersion: nil
            )
        )
        XCTAssertFalse(
            SafariExtensionNotice.shouldShow(
                isEnabled: true,
                currentVersion: "1.0.1",
                shownVersion: "1.0.0"
            )
        )
    }

    func testEmptyVersionDoesNotShow() {
        XCTAssertFalse(
            SafariExtensionNotice.shouldShow(
                isEnabled: false,
                currentVersion: "",
                shownVersion: nil
            )
        )
    }

    func testApplyRecordsShownVersionOncePerRelease() {
        let first = SafariExtensionNotice.applied(
            isEnabled: nil,
            currentVersion: "1.0.1",
            shownVersion: nil
        )
        XCTAssertFalse(first.show)
        XCTAssertNil(first.shownVersion)

        let shown = SafariExtensionNotice.applied(
            isEnabled: false,
            currentVersion: "1.0.1",
            shownVersion: first.shownVersion
        )
        XCTAssertTrue(shown.show)
        XCTAssertEqual(shown.shownVersion, "1.0.1")

        let again = SafariExtensionNotice.applied(
            isEnabled: false,
            currentVersion: "1.0.1",
            shownVersion: shown.shownVersion
        )
        XCTAssertFalse(again.show)
        XCTAssertEqual(again.shownVersion, "1.0.1")

        let next = SafariExtensionNotice.applied(
            isEnabled: false,
            currentVersion: "1.1.0",
            shownVersion: again.shownVersion
        )
        XCTAssertTrue(next.show)
        XCTAssertEqual(next.shownVersion, "1.1.0")
    }

    func testCopyNamesUmbilicalAndHasNoEmDash() {
        XCTAssertTrue(SafariExtensionNotice.message.contains("umbilical"))
        XCTAssertFalse(SafariExtensionNotice.message.contains("Umbilical"))
        XCTAssertFalse(SafariExtensionNotice.message.contains("\u{2014}"))
        XCTAssertFalse(SafariExtensionNotice.message.contains("\u{2013}"))
        XCTAssertEqual(
            SafariExtensionNotice.extensionBundleIdentifier,
            "me.peapod.umbilical.extension"
        )
    }
}
