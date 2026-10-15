// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum HandoffGesture: Equatable {
    case download
    case cancel
    /// Return, which is the Cancel button's default shortcut.
    case `return`
}

public enum HandoffGestureDecision: Equatable {
    case ignore
    case confirm
    case decline
}

/// Whether the confirmation sheet may start a download.
/// Download is never the default. The first second ignores every gesture.
public struct HandoffConfirmationGate: Equatable {
    public static let armDelay: TimeInterval = 1

    public let appearedAt: Date

    public init(appearedAt: Date) {
        self.appearedAt = appearedAt
    }

    public func decide(_ gesture: HandoffGesture, at now: Date) -> HandoffGestureDecision {
        if now.timeIntervalSince(appearedAt) < Self.armDelay {
            return .ignore
        }
        switch gesture {
        case .download:
            return .confirm
        case .cancel, .return:
            return .decline
        }
    }

    /// Host when the link has one. A magnet has no host, so the label is the scheme.
    public static func prominentLabel(for url: URL) -> String {
        if let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty {
            return host
        }
        return url.scheme?.lowercased() ?? ""
    }
}
