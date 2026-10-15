// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalEngine
import XCTest

@testable import UmbilicalUI

final class HelperLocatorTests: XCTestCase {
    func testEnvironmentOverridesCandidatesWhenExecutable() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fromEnv = try executable(named: "from-env", in: directory)
        let other = try executable(named: "other", in: directory)
        let found = HelperLocator.firstExecutable(
            environment: ["ARIA2C": fromEnv.path],
            key: "ARIA2C",
            candidates: [other]
        )
        XCTAssertEqual(found?.path, fromEnv.path)
    }

    func testMissingEnvironmentFallsThrough() throws {
        let directory = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let other = try executable(named: "other", in: directory)
        let found = HelperLocator.firstExecutable(
            environment: ["ARIA2C": directory.appendingPathComponent("missing").path],
            key: "ARIA2C",
            candidates: [other]
        )
        XCTAssertEqual(found?.path, other.path)
        let none = HelperLocator.firstExecutable(
            environment: ["ARIA2C": ""],
            key: "ARIA2C",
            candidates: []
        )
        XCTAssertNil(none)
    }

    private func executable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}

final class SettingsStoreTests: XCTestCase {
    func testUserDefaultsRoundTrip() throws {
        let name = "umb-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let store = UserDefaultsSettingsStore(
            defaults: defaults,
            settingsKey: "settings",
            historyKey: "history"
        )
        let settings = AppSettings(
            downloadDirectoryPath: "/tmp/umb-downloads",
            notifyOnComplete: false,
            notifyOnFailure: true
        )
        store.saveSettings(settings)
        XCTAssertEqual(store.loadSettings(), settings)
        let finished = FinishedDownload(
            id: "history-g1-1",
            title: "file.bin",
            detail: "https://example.com/file.bin",
            totalLength: 12,
            filePath: "/tmp/umb-downloads/file.bin",
            finishedAt: Date(timeIntervalSince1970: 10)
        )
        store.saveHistory([finished])
        XCTAssertEqual(store.loadHistory(), [finished])
    }

    func testCorruptPayloadsFallBack() throws {
        let name = "umb-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("nope".utf8), forKey: "settings")
        defaults.set(Data("nope".utf8), forKey: "history")
        let store = UserDefaultsSettingsStore(
            defaults: defaults,
            settingsKey: "settings",
            historyKey: "history"
        )
        XCTAssertEqual(store.loadSettings(), AppSettings())
        XCTAssertTrue(store.loadHistory().isEmpty)
    }
}

final class ConfiguredEngineTests: XCTestCase {
    func testMissingHelpersAreRejectedBeforeLaunch() async {
        let engine = ConfiguredEngine(aria2: nil, watch: nil)
        do {
            _ = try await engine.start(downloadDirectory: URL(fileURLWithPath: "/tmp"))
            XCTFail("expected a missing helper")
        } catch let error as EngineError {
            guard case .executableMissing(let path) = error else {
                XCTFail("unexpected \(error)")
                return
            }
            XCTAssertEqual(path, "aria2c")
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}
