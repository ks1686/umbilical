// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public struct AppSettings: Codable, Equatable {
    public var downloadDirectoryPath: String?
    public var notifyOnComplete: Bool
    public var notifyOnFailure: Bool

    public init(
        downloadDirectoryPath: String? = nil,
        notifyOnComplete: Bool = true,
        notifyOnFailure: Bool = true
    ) {
        self.downloadDirectoryPath = downloadDirectoryPath
        self.notifyOnComplete = notifyOnComplete
        self.notifyOnFailure = notifyOnFailure
    }
}

public struct FinishedDownload: Codable, Equatable {
    public var id: String
    public var title: String
    public var detail: String
    public var totalLength: Int64
    public var filePath: String?
    public var finishedAt: Date
}

public protocol SettingsStoring: AnyObject {
    func loadSettings() -> AppSettings
    func saveSettings(_ settings: AppSettings)
    func loadHistory() -> [FinishedDownload]
    func saveHistory(_ history: [FinishedDownload])
}

public final class UserDefaultsSettingsStore: SettingsStoring {
    private let defaults: UserDefaults
    private let settingsKey: String
    private let historyKey: String

    public init(
        defaults: UserDefaults,
        settingsKey: String = "umb.settings",
        historyKey: String = "umb.history"
    ) {
        self.defaults = defaults
        self.settingsKey = settingsKey
        self.historyKey = historyKey
    }

    public func loadSettings() -> AppSettings {
        guard let data = defaults.data(forKey: settingsKey) else {
            return AppSettings()
        }
        return (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()
    }

    public func saveSettings(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: settingsKey)
    }

    public func loadHistory() -> [FinishedDownload] {
        guard let data = defaults.data(forKey: historyKey) else { return [] }
        return (try? JSONDecoder().decode([FinishedDownload].self, from: data)) ?? []
    }

    public func saveHistory(_ history: [FinishedDownload]) {
        guard let data = try? JSONEncoder().encode(history) else { return }
        defaults.set(data, forKey: historyKey)
    }
}
