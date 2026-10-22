// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

final class AppSceneTests: XCTestCase {
    func testAppDeclaresASingleMainWindow() throws {
        let source = try readAppSource("UmbilicalApp.swift")
        XCTAssertTrue(source.contains("Window(\"umbilical\", id: \"main\")"))
        XCTAssertFalse(source.contains("WindowGroup"))
        XCTAssertTrue(source.contains("onOpenURL"))
        XCTAssertTrue(source.contains("applicationShouldOpenUntitledFile"))
        XCTAssertTrue(source.contains("applicationDidFinishLaunching"))
        XCTAssertTrue(source.contains("closeRestoredExtraWindows"))
        XCTAssertTrue(source.contains("endSheet"))
        XCTAssertTrue(source.contains("application(_: NSApplication, open urls:"))
        let menu = try readAppSource("MenuBarMenu.swift")
        XCTAssertTrue(menu.contains("openWindow(id: \"main\")"))
        let list = try readAppSource("DownloadList.swift")
        XCTAssertTrue(list.contains("if row.showsPauseResume"))
        let bridge = try readAppSource("SafariExtensionBridge.swift")
        XCTAssertTrue(bridge.contains("SFSafariExtensionManager.getStateOfSafariExtension"))
        XCTAssertTrue(bridge.contains("SFSafariApplication.showPreferencesForExtension"))
        let banner = try readAppSource("SafariExtensionNoticeBanner.swift")
        XCTAssertTrue(banner.contains("SafariExtensionNotice.message"))
        XCTAssertTrue(banner.contains("SafariExtensionBridge.showPreferences"))
    }

    private func readAppSource(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App")
            .appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
