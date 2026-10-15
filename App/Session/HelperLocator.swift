// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum HelperLocator {
    public static func firstExecutable(
        environment: [String: String],
        key: String,
        candidates: [URL]
    ) -> URL? {
        if let raw = environment[key], !raw.isEmpty {
            let url = URL(fileURLWithPath: raw)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        for candidate in candidates {
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }
}
