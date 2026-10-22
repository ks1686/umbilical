// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum HandoffEnqueueResult: Equatable {
    case accepted
    case overflow
}

/// Holds confirm requests so a later open cannot replace an earlier sheet.
/// Finishing the current item never approves a pending one.
public struct HandoffConfirmQueue<Item> {
    public static var pendingLimit: Int { 10 }
    public static var overflowMessage: String {
        "Too many downloads are waiting for confirmation. Finish or cancel the open ones first."
    }

    public private(set) var current: Item?
    public private(set) var pending: [Item] = []

    public init() {}

    @discardableResult
    public mutating func enqueue(_ item: Item) -> HandoffEnqueueResult {
        if current == nil {
            current = item
            return .accepted
        }
        if pending.count >= Self.pendingLimit {
            return .overflow
        }
        pending.append(item)
        return .accepted
    }

    /// Drops the open sheet only. Pending items stay unconfirmed.
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
