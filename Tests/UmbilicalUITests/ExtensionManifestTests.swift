// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

final class ExtensionManifestTests: XCTestCase {
    func testManifestKeepsCaptureOptIn() throws {
        let json = try readJSON("manifest.json")
        XCTAssertEqual(json["manifest_version"] as? Int, 3)
        XCTAssertEqual(json["version"] as? String, try marketingVersion())
        XCTAssertEqual(
            json["permissions"] as? [String],
            ["activeTab", "contextMenus", "nativeMessaging", "storage"]
        )
        XCTAssertNil(json["host_permissions"])
        XCTAssertEqual(json["optional_host_permissions"] as? [String], ["<all_urls>"])
        XCTAssertFalse((json["permissions"] as? [String] ?? []).contains("<all_urls>"))
        XCTAssertNil(json["optional_permissions"])
        let scripts = try XCTUnwrap(json["content_scripts"] as? [[String: Any]])
        XCTAssertEqual(scripts.count, 1)
        XCTAssertEqual(scripts[0]["js"] as? [String], ["content.js"])
        XCTAssertEqual(scripts[0]["matches"] as? [String], ["http://*/*", "https://*/*"])
        XCTAssertEqual(scripts[0]["all_frames"] as? Bool, true)
        let background = try XCTUnwrap(json["background"] as? [String: Any])
        XCTAssertEqual(
            background["scripts"] as? [String],
            ["website-access.js", "background.js"]
        )
        XCTAssertEqual(background["persistent"] as? Bool, false)
        XCTAssertNil(background["service_worker"])
    }

    func testManifestVersionMatchesAppMarketingVersion() throws {
        let version = try marketingVersion()
        XCTAssertEqual(version, "1.0.2")
        let json = try readJSON("manifest.json")
        XCTAssertEqual(json["version"] as? String, version)
    }

    func testBackgroundSendsOnlyTheClickedLink() throws {
        let source = try readText("background.js")
        XCTAssertTrue(source.contains("activeTab"))
        XCTAssertTrue(source.contains("info.linkUrl"))
        XCTAssertTrue(source.contains("sendNativeMessage"))
        XCTAssertTrue(source.contains("onInstalled"))
        XCTAssertTrue(source.contains("onStartup"))
        XCTAssertTrue(source.contains("onAdded"))
        XCTAssertTrue(source.contains("download-video-with-umbilical"))
        XCTAssertTrue(source.contains("umbilical-intercept"))
        XCTAssertTrue(source.contains("umbilicalWebsiteAccess"))
        XCTAssertTrue(source.contains("hasWebsiteAccess"))
        XCTAssertFalse(source.contains("browser.downloads"))
        XCTAssertFalse(source.contains("chrome.downloads"))
        XCTAssertFalse(source.contains("executeScript"))
        XCTAssertFalse(source.contains("selectionText"))
        XCTAssertFalse(source.contains("cookies"))
    }

    func testPopupDocumentsWebsiteAccessAndRestoresCapture() throws {
        let html = try readText("popup.html")
        XCTAssertTrue(html.contains("Right-click a link"))
        XCTAssertTrue(html.contains("does not read the page"))
        XCTAssertTrue(html.contains("Allow website access"))
        XCTAssertTrue(html.contains("Safari Settings"))
        XCTAssertTrue(html.contains("access to all websites"))
        XCTAssertTrue(html.contains("Option-click"))
        XCTAssertTrue(html.contains("popup.js"))
        XCTAssertTrue(html.contains("Intercept download links"))
        XCTAssertTrue(html.contains("Download this page with umbilical"))
        let popup = try readText("popup.js")
        XCTAssertTrue(html.contains("website-access.js"))
        XCTAssertTrue(popup.contains("permissions.request"))
        XCTAssertTrue(popup.contains("<all_urls>"))
        XCTAssertTrue(popup.contains("captureDownloads"))
        XCTAssertTrue(popup.contains("umbilicalWebsiteAccess"))
        XCTAssertTrue(popup.contains("activeTab") || popup.contains("tabs.query"))
        XCTAssertTrue(popup.contains("video = true") || popup.contains("video: true"))
        XCTAssertFalse(popup.contains("downloads.download"))
        XCTAssertFalse(popup.contains("if (enabled && !granted)"))
        XCTAssertFalse(popup.contains("host_permissions"))
        let access = try readText("website-access.js")
        XCTAssertTrue(access.contains("*://*/*"))
        XCTAssertTrue(access.contains("http://*/*"))
        XCTAssertTrue(access.contains("https://*/*"))
        XCTAssertTrue(access.contains("originsCoverHttpAndHttps"))
        XCTAssertFalse(access.contains("host_permissions"))
    }

    func testHostAppTellsUsersToAllowSafariWebsiteAccess() throws {
        let settings = try readApp("SettingsView.swift")
        XCTAssertTrue(settings.contains("Safari Settings > Extensions > umbilical"))
        XCTAssertTrue(settings.contains("Allow website access"))
        let empty = try readApp("ContentView.swift")
        XCTAssertTrue(empty.contains("Safari Settings > Extensions > umbilical"))
    }

    func testContentScriptReadsOnlyTheClickedLink() throws {
        let source = try readText("content.js")
        XCTAssertTrue(source.contains("getAttribute(\"href\")"))
        XCTAssertTrue(source.contains("getAttribute(\"download\")"))
        XCTAssertTrue(source.contains("getAttribute(\"type\")"))
        XCTAssertTrue(source.contains("altKey"))
        XCTAssertTrue(source.contains("preventDefault"))
        XCTAssertTrue(source.contains("magnet:?"))
        XCTAssertTrue(source.contains("xt=urn:btih:"))
        XCTAssertTrue(source.contains("xt=urn:btmh:"))
        XCTAssertTrue(source.contains("application/x-bittorrent"))
        XCTAssertTrue(source.contains("passThrough"))
        XCTAssertTrue(source.contains("if (!event.isTrusted) return;"))
        XCTAssertFalse(source.contains("innerText"))
        XCTAssertFalse(source.contains("textContent"))
        XCTAssertFalse(source.contains("document.cookie"))
        XCTAssertFalse(source.contains("cookieStore"))
        XCTAssertFalse(source.contains("document.body"))
        XCTAssertFalse(source.contains("querySelectorAll"))
        for ext in ["torrent", "metalink", "meta4", "zip", "pdf"] {
            XCTAssertTrue(source.contains("\"\(ext)\""), ext)
        }
    }

    func testContentScriptHeuristics() throws {
        try runNodeTest("content-capture-test.js")
    }

    func testWebsiteAccessGrantPatterns() throws {
        try runNodeTest("website-access-test.js")
    }

    func testOpeningPopupDoesNotClearCapture() throws {
        try runNodeTest("popup-capture-test.js")
    }

    private func marketingVersion() throws -> String {
        let yaml = try String(
            contentsOf: repoRoot().appendingPathComponent("project.yml"),
            encoding: .utf8
        )
        let pattern = try NSRegularExpression(
            pattern: #"MARKETING_VERSION:\s*"([^"]+)""#
        )
        let range = NSRange(yaml.startIndex..<yaml.endIndex, in: yaml)
        let matches = pattern.matches(in: yaml, range: range)
        XCTAssertEqual(matches.count, 2)
        var versions: [String] = []
        for match in matches {
            let capture = match.range(at: 1)
            let captured = try XCTUnwrap(Range(capture, in: yaml))
            versions.append(String(yaml[captured]))
        }
        XCTAssertEqual(Set(versions).count, 1)
        return try XCTUnwrap(versions.first)
    }

    private func runNodeTest(_ name: String) throws {
        guard let executable = nodeExecutable() else {
            throw XCTSkip("node is not installed")
        }
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [script.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, output)
    }

    private func nodeExecutable() -> String? {
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["NODE"], !env.isEmpty {
            candidates.append(env)
        }
        candidates.append(contentsOf: [
            "/exec-daemon/node",
            "/usr/bin/node",
            "/usr/local/bin/node"
        ])
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for directory in path.split(separator: ":") {
            candidates.append("\(directory)/node")
        }
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
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
