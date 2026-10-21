// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

final class AppInfoPlistTests: XCTestCase {
    func testAppRegistersTorrentMetalinkAndMagnetOpeners() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("App/Info.plist")
        let data = try Data(contentsOf: url)
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        let plist = try XCTUnwrap(object as? [String: Any])
        let urlTypes = try XCTUnwrap(plist["CFBundleURLTypes"] as? [[String: Any]])
        var schemes: [String] = []
        for item in urlTypes {
            let listed = item["CFBundleURLSchemes"] as? [String] ?? []
            schemes.append(contentsOf: listed)
        }
        XCTAssertTrue(schemes.contains("umbilical"))
        XCTAssertTrue(schemes.contains("magnet"))
        let documents = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        var extensions: [String] = []
        for item in documents {
            extensions.append(contentsOf: item["CFBundleTypeExtensions"] as? [String] ?? [])
        }
        XCTAssertTrue(extensions.contains("torrent"))
        XCTAssertTrue(extensions.contains("metalink"))
        XCTAssertTrue(extensions.contains("meta4"))
        let imported = try XCTUnwrap(plist["UTImportedTypeDeclarations"] as? [[String: Any]])
        XCTAssertFalse(imported.isEmpty)
    }
}
