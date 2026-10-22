// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

final class ExtensionManifestTests: XCTestCase {
    func testManifestKeepsTheSafariMenuGrantTight() throws {
        let json = try readJSON("manifest.json")
        XCTAssertEqual(json["manifest_version"] as? Int, 3)
        XCTAssertEqual(json["version"] as? String, "1.0.1")
        XCTAssertEqual(
            json["permissions"] as? [String],
            ["activeTab", "contextMenus", "nativeMessaging"]
        )
        XCTAssertNil(json["host_permissions"])
        XCTAssertEqual(json["optional_host_permissions"] as? [String], ["<all_urls>"])
        XCTAssertFalse((json["permissions"] as? [String] ?? []).contains("<all_urls>"))
        XCTAssertNil(json["optional_permissions"])
        XCTAssertNil(json["content_scripts"])
        let background = try XCTUnwrap(json["background"] as? [String: Any])
        XCTAssertEqual(background["scripts"] as? [String], ["background.js"])
        XCTAssertEqual(background["persistent"] as? Bool, false)
        XCTAssertNil(background["service_worker"])
    }

    func testBackgroundSendsOnlyTheClickedLink() throws {
        let source = try readText("background.js")
        XCTAssertTrue(source.contains("activeTab"))
        XCTAssertTrue(source.contains("info.linkUrl"))
        XCTAssertTrue(source.contains("sendNativeMessage"))
        XCTAssertTrue(source.contains("onInstalled"))
        XCTAssertTrue(source.contains("onStartup"))
        XCTAssertTrue(source.contains("onAdded"))
        XCTAssertFalse(source.contains("downloads"))
        XCTAssertFalse(source.contains("executeScript"))
        XCTAssertFalse(source.contains("selectionText"))
        XCTAssertFalse(source.contains("pageUrl"))
        XCTAssertFalse(source.contains("cookies"))
    }

    func testPopupRequestsOptionalWebsiteAccess() throws {
        let html = try readText("popup.html")
        XCTAssertTrue(html.contains("Right-click a link"))
        XCTAssertTrue(html.contains("does not read the page"))
        XCTAssertTrue(html.contains("Allow website access"))
        XCTAssertTrue(html.contains("Safari Settings"))
        XCTAssertTrue(html.contains("popup.js"))
        XCTAssertFalse(html.contains("capture"))
        let popup = try readText("popup.js")
        XCTAssertTrue(popup.contains("permissions.request"))
        XCTAssertTrue(popup.contains("<all_urls>"))
        XCTAssertFalse(popup.contains("capture"))
    }

    func testHostAppTellsUsersToAllowSafariWebsiteAccess() throws {
        let settings = try readApp("SettingsView.swift")
        XCTAssertTrue(settings.contains("Safari Settings > Extensions > umbilical"))
        XCTAssertTrue(settings.contains("Allow website access"))
        let empty = try readApp("ContentView.swift")
        XCTAssertTrue(empty.contains("Safari Settings > Extensions > umbilical"))
    }

    private func readJSON(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: resourceURL(name))
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    private func readText(_ name: String) throws -> String {
        try String(contentsOf: resourceURL(name), encoding: .utf8)
    }

    private func resourceURL(_ name: String) -> URL {
        repoRoot().appendingPathComponent("Extension/Resources/\(name)")
    }

    private func readApp(_ name: String) throws -> String {
        try String(contentsOf: repoRoot().appendingPathComponent("App/\(name)"), encoding: .utf8)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
