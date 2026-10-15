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
        var ytDlp: URL?
    }

    static func locate() -> Located {
        // Release builds ignore ARIA2C, UMB_WATCH, and YT_DLP.
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            let allowEnvironmentOverride = true
        #else
            let environment: [String: String] = [:]
            let allowEnvironmentOverride = false
        #endif
        let watch = HelperLocator.firstExecutable(
            environment: environment,
            key: "UMB_WATCH",
            candidates: [contentsHelpers("umb-watch")],
            allowEnvironmentOverride: allowEnvironmentOverride
        )
        let aria2 = HelperLocator.firstExecutable(
            environment: environment,
            key: "ARIA2C",
            candidates: [contentsHelpers("aria2c")],
            allowEnvironmentOverride: allowEnvironmentOverride
        )
        let ytDlp = HelperLocator.firstExecutable(
            environment: environment,
            key: "YT_DLP",
            candidates: [contentsHelpers("yt-dlp")],
            allowEnvironmentOverride: allowEnvironmentOverride
        )
        return Located(
            status: HelperStatus(
                aria2Found: aria2 != nil,
                watchFound: watch != nil,
                ytDlpFound: ytDlp != nil
            ),
            aria2: aria2,
            watch: watch,
            ytDlp: ytDlp
        )
    }

    private static func contentsHelpers(_ name: String) -> URL {
        Bundle.main.bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent(name)
    }
}
