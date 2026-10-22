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
        XCTAssertTrue(source.contains("refreshSafariNotice"))
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
        let content = try readAppSource("ContentView.swift")
        XCTAssertFalse(content.contains(".alert("))
        XCTAssertTrue(content.contains("presentNextStagedHandoff"))
        XCTAssertTrue(content.contains("onDismiss"))
        let appModel = try readAppSource("AppModel.swift")
        XCTAssertTrue(appModel.contains("HandoffConfirmQueue"))
        XCTAssertTrue(appModel.contains("overflowMessage"))
        let confirm = slice(
            appModel,
            from: "func confirmStagedHandoff",
            to: "func declineStagedHandoff"
        )
        XCTAssertFalse(confirm.contains("presentNextStagedHandoff"))
        XCTAssertFalse(confirm.contains("presentNextIfIdle"))
        let actions = try readAppSource("MacActions.swift")
        XCTAssertTrue(actions.contains("presentRejectedDownload"))
        XCTAssertTrue(actions.contains("beginTermination"))
        XCTAssertTrue(source.contains("beginTermination"))
    }

    private func slice(_ source: String, from: String, to: String) -> String {
        guard let start = source.range(of: from), let end = source.range(of: to),
            start.lowerBound < end.lowerBound
        else {
            return ""
        }
        return String(source[start.lowerBound..<end.lowerBound])
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
