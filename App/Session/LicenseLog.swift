// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if os(macOS)
    import os
#endif

enum LicenseLog {
    static func write(_ message: String) {
        #if os(macOS)
            logger.log("\(message, privacy: .public)")
        #endif
    }

    static func errorName(_ error: Error) -> String {
        String(reflecting: type(of: error))
    }

    #if os(macOS)
        private static let logger = Logger(subsystem: "me.peapod.umbilical", category: "license")
    #endif
}
