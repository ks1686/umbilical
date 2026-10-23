// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import UmbilicalUI

enum MenuBarStatusItem {
    static func templateImage() -> NSImage {
        let image = NSImage(named: "MenuBarIcon") ?? NSImage()
        MenuBarAccessibility.apply(to: image)
        return image
    }

    static func applyToOpenStatusButtons() {
        for window in NSApp.windows {
            if let button = statusButton(in: window) {
                MenuBarAccessibility.apply(to: button)
            }
        }
    }

    static func statusButton(in window: NSWindow) -> NSStatusBarButton? {
        if let button = window.contentView as? NSStatusBarButton {
            return button
        }
        return window.contentView?.subviews.compactMap { $0 as? NSStatusBarButton }.first
    }
}

/// Walks from the MenuBarExtra label into the status button so AXDescription
/// is set even when the extra's title string is empty.
struct MenuBarStatusItemAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView {
        AnchorView()
    }

    func updateNSView(_ nsView: AnchorView, context: Context) {
        nsView.apply()
    }

    final class AnchorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            setAccessibilityElement(false)
            apply()
        }

        func apply() {
            setAccessibilityElement(false)
            if let button = enclosingStatusButton() {
                MenuBarAccessibility.apply(to: button)
            }
            MenuBarStatusItem.applyToOpenStatusButtons()
        }

        private func enclosingStatusButton() -> NSStatusBarButton? {
            var view: NSView? = self
            while let current = view {
                if let button = current as? NSStatusBarButton {
                    return button
                }
                view = current.superview
            }
            return window.flatMap(MenuBarStatusItem.statusButton(in:))
        }
    }
}
