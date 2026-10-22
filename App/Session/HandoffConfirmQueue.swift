// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Holds confirm requests so a later open cannot replace an earlier sheet.
public struct HandoffConfirmQueue<Item> {
    public private(set) var current: Item?
    public private(set) var pending: [Item] = []

    public init() {}

    public mutating func enqueue(_ item: Item) {
        if current == nil {
            current = item
        } else {
            pending.append(item)
        }
    }

    public mutating func clearCurrent() {
        current = nil
    }

    public mutating func presentNextIfIdle() {
        guard current == nil, !pending.isEmpty else {
            return
        }
        current = pending.removeFirst()
    }
}
