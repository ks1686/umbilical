// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

final class SafariExtensionNoticeTests: XCTestCase {
    func testDisabledOrUnknownShowsUntilDismissedForThisVersion() {
        XCTAssertTrue(
            SafariExtensionNotice.shouldShow(
                isEnabled: false,
                currentVersion: "1.0.1",
                dismissedVersion: nil
            )
        )
        XCTAssertTrue(
            SafariExtensionNotice.shouldShow(
                isEnabled: nil,
                currentVersion: "1.0.1",
                dismissedVersion: nil
            )
        )
        XCTAssertFalse(
            SafariExtensionNotice.shouldShow(
                isEnabled: false,
                currentVersion: "1.0.1",
                dismissedVersion: "1.0.1"
            )
        )
        XCTAssertFalse(
            SafariExtensionNotice.shouldShow(
                isEnabled: nil,
                currentVersion: "1.0.1",
                dismissedVersion: "1.0.1"
            )
        )
    }

    func testNextVersionCanShowAgain() {
        XCTAssertTrue(
            SafariExtensionNotice.shouldShow(
                isEnabled: false,
                currentVersion: "1.1.0",
                dismissedVersion: "1.0.1"
            )
        )
    }

    func testEnabledExtensionNeverShows() {
        XCTAssertFalse(
            SafariExtensionNotice.shouldShow(
                isEnabled: true,
                currentVersion: "1.0.1",
                dismissedVersion: nil
            )
        )
        XCTAssertFalse(
            SafariExtensionNotice.shouldShow(
                isEnabled: true,
                currentVersion: "1.0.1",
                dismissedVersion: "1.0.0"
            )
        )
    }

    func testEmptyVersionDoesNotShow() {
        XCTAssertFalse(
            SafariExtensionNotice.shouldShow(
                isEnabled: false,
                currentVersion: "",
                dismissedVersion: nil
            )
        )
    }

    func testUnavailableStateCountsAsDisabled() {
        XCTAssertTrue(SafariExtensionNotice.isDisabled(nil))
        XCTAssertTrue(SafariExtensionNotice.isDisabled(false))
        XCTAssertFalse(SafariExtensionNotice.isDisabled(true))
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
        XCTAssertEqual(
            SafariExtensionNotice.dismissedVersionKey,
            "umb.safariExtensionNoticeDismissedVersion"
        )
    }
}
