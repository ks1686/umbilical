// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalUI

#if canImport(AppKit)
    import AppKit
#endif

final class MenuBarAccessibilityTests: XCTestCase {
    func testStatusItemDescriptionIsUmbilicalWhenIdleTitleIsEmpty() {
        XCTAssertEqual(MenuBarAccessibility.description, "umbilical")
        XCTAssertEqual(MenuBarSummary.idleTitle, "")
        XCTAssertEqual(MenuBarSummary.title(for: []), "")
    }

    #if canImport(AppKit)
        func testImageAndStatusButtonCarryTheDescription() {
            let image = NSImage(size: NSSize(width: 18, height: 18))
            MenuBarAccessibility.apply(to: image)
            XCTAssertEqual(image.accessibilityDescription, "umbilical")
            XCTAssertTrue(image.isTemplate)

            let button = NSStatusBarButton()
            button.title = ""
            button.image = NSImage(size: NSSize(width: 18, height: 18))
            MenuBarAccessibility.apply(to: button)
            XCTAssertEqual(button.image?.accessibilityDescription, "umbilical")
            XCTAssertEqual(button.accessibilityLabel(), "umbilical")
            XCTAssertEqual(button.image?.isTemplate, true)
        }
    #endif
}
