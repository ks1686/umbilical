// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

enum ExternalURLSender {
    /// A short label for the confirmation sheet. The label does not skip confirmation.
    static func label() -> String {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else {
            return "An external source"
        }
        guard let descriptor = event.attributeDescriptor(forKeyword: keySenderPIDAttr) else {
            return "An external source"
        }
        let pid = pid_t(descriptor.int32Value)
        guard pid > 0, let app = NSRunningApplication(processIdentifier: pid) else {
            return "An external source"
        }
        let bundle = app.bundleIdentifier ?? ""
        if bundle == "me.peapod.umbilical.extension" || bundle.hasPrefix("com.apple.Safari") {
            return "Safari"
        }
        if let name = app.localizedName, !name.isEmpty {
            return name
        }
        return "An external source"
    }
}
