// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Chooses which restored AppKit windows to keep after launch.
///
/// A unique SwiftUI `Window(id: "main")` still restores leftover
/// multi-instance windows from Saved Application State. macOS 14 has no
/// `restorationBehavior` scene API, so extras are closed after launch.
public enum RestoredWindowFilter {
    public struct Snapshot: Equatable {
        public var title: String
        public var identifier: String
        public var isPanel: Bool
        public var canBecomeMain: Bool

        public init(
            title: String,
            identifier: String,
            isPanel: Bool,
            canBecomeMain: Bool
        ) {
            self.title = title
            self.identifier = identifier
            self.isPanel = isPanel
            self.canBecomeMain = canBecomeMain
        }
    }

    public static func indicesToClose(_ windows: [Snapshot]) -> [Int] {
        let content = windows.enumerated().filter { _, window in
            isContent(window)
        }
        guard content.count > 1 else {
            return []
        }
        let keep =
            content.first { _, window in
                window.identifier == "main"
            } ?? content.first { _, window in
                window.title == "umbilical"
            } ?? content.first
        guard let keep else {
            return []
        }
        return content.compactMap { index, _ in
            index == keep.offset ? nil : index
        }
    }

    public static func isContent(_ window: Snapshot) -> Bool {
        if window.isPanel || !window.canBecomeMain {
            return false
        }
        if isSettings(window) {
            return false
        }
        return true
    }

    public static func isSettings(_ window: Snapshot) -> Bool {
        let title = window.title.lowercased()
        let identifier = window.identifier.lowercased()
        return title.contains("settings") || identifier.contains("settings")
    }
}
