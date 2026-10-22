// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum SessionPhase: Equatable {
    case needsFolder
    case starting
    case running
    case failed
}

public struct HelperStatus: Equatable {
    public var aria2Found: Bool
    public var watchFound: Bool
    public var ytDlpFound: Bool

    public init(aria2Found: Bool, watchFound: Bool, ytDlpFound: Bool = false) {
        self.aria2Found = aria2Found
        self.watchFound = watchFound
        self.ytDlpFound = ytDlpFound
    }
}

public struct VideoHelpers: Equatable {
    public var ytDlp: URL?
    public var watch: URL?

    public init(ytDlp: URL?, watch: URL?) {
        self.ytDlp = ytDlp
        self.watch = watch
    }
}

public struct DownloadNotice: Equatable, Identifiable {
    public enum Kind: Equatable {
        case completed
        case failed
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let body: String
}

public struct MenuDownload: Equatable, Identifiable {
    public let id: String
    public let label: String
}

public struct DownloadRow: Equatable, Identifiable {
    public let id: String
    public var title: String
    public var detail: String
    public var fraction: Double?
    public var showsIndeterminateProgress: Bool
    public var speedText: String
    public var etaText: String
    public var sizeText: String
    public var stateText: String
    public var errorMessage: String?
    public var filePath: String?
    public var canPause: Bool
    public var canResume: Bool
    public var canRemove: Bool
    public var cancelsLiveVideo: Bool
    public var isComplete: Bool
    public var isActive: Bool
    public var showsInMenu: Bool
    public var bytesPerSecond: Int64

    public var showsPauseResume: Bool {
        canPause || canResume
    }
}

public struct SessionSnapshot: Equatable {
    public var rows: [DownloadRow]
    public var menuRows: [MenuDownload]
    public var menuTitle: String
    public var downloadDirectoryPath: String?
    public var phase: SessionPhase
    public var message: String?
    public var notifyOnComplete: Bool
    public var notifyOnFailure: Bool
    public var helpers: HelperStatus
    public var canAdd: Bool

    public static let empty = SessionSnapshot(
        rows: [],
        menuRows: [],
        menuTitle: MenuBarSummary.idleTitle,
        downloadDirectoryPath: nil,
        phase: .needsFolder,
        message: nil,
        notifyOnComplete: true,
        notifyOnFailure: true,
        helpers: HelperStatus(aria2Found: false, watchFound: false),
        canAdd: false
    )
}

public enum SessionError: Error, Equatable, CustomStringConvertible {
    case folderMissing
    case engineNotRunning
    case folderChangeBlocked

    public var description: String {
        switch self {
        case .folderMissing:
            return "Choose a download folder first."
        case .engineNotRunning:
            return "The download engine is not running."
        case .folderChangeBlocked:
            return "Finish or remove downloads before changing the folder."
        }
    }
}
