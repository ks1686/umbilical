// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalUI

enum AppHelpers {
    struct Located {
        var status: HelperStatus
        var aria2: URL?
        var watch: URL?
    }

    static func locate() -> Located {
        let environment = ProcessInfo.processInfo.environment
        let watch = HelperLocator.firstExecutable(
            environment: environment,
            key: "UMB_WATCH",
            candidates: watchCandidates()
        )
        let aria2 = HelperLocator.firstExecutable(
            environment: environment,
            key: "ARIA2C",
            candidates: aria2Candidates()
        )
        return Located(
            status: HelperStatus(aria2Found: aria2 != nil, watchFound: watch != nil),
            aria2: aria2,
            watch: watch
        )
    }

    private static func watchCandidates() -> [URL] {
        var urls: [URL] = []
        if let auxiliary = Bundle.main.url(forAuxiliaryExecutable: "umb-watch") {
            urls.append(auxiliary)
        }
        if let executable = Bundle.main.executableURL {
            let sibling =
                executable
                .deletingLastPathComponent()
                .appendingPathComponent("umb-watch")
            urls.append(sibling)
        }
        return urls
    }

    private static func aria2Candidates() -> [URL] {
        let helpers = Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("aria2c")
        return [helpers]
    }
}
