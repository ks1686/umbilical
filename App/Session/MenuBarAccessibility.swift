// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

#if canImport(AppKit)
    import AppKit
#endif

/// Status item name. Idle has no title text, so the image and status button
/// must carry this as AXDescription.
public enum MenuBarAccessibility {
    public static let description = "umbilical"
}

#if canImport(AppKit)
    extension MenuBarAccessibility {
        public static func apply(to image: NSImage) {
            image.isTemplate = true
            image.accessibilityDescription = description
        }

        public static func apply(to button: NSStatusBarButton) {
            if let image = button.image {
                apply(to: image)
            }
            button.setAccessibilityLabel(description)
        }
    }
#endif
