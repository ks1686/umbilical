// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalEngine

@MainActor
public final class DownloadSessionModel {
    public static let chooseFolderMessage = "Choose a download folder to start."
    public static let historyLimit = 200

    public internal(set) var snapshot: SessionSnapshot = .empty

    let engine: any EngineLaunching
    let store: any SettingsStoring
    let helpers: HelperStatus
    let video: VideoHelpers
    let quarantine: any QuarantineApplying
    let clock: () -> Date
    var settings: AppSettings
    var history: [FinishedDownload]
    var directory: URL?
    var client: (any DownloadControlling)?
    var tracked: [TrackedDownload] = []
    var notices: [DownloadNotice] = []
    var phase: SessionPhase = .needsFolder
    var message: String?
    var refreshOwnsMessage = false
    var refreshing = false
    var videoJobs: [String: VideoDownloadJob] = [:]

    public init(
        engine: any EngineLaunching,
        store: any SettingsStoring,
        helpers: HelperStatus,
        video: VideoHelpers = VideoHelpers(ytDlp: nil, watch: nil),
        quarantine: any QuarantineApplying = SystemQuarantine(),
        clock: @escaping () -> Date = { Date() }
    ) {
        self.engine = engine
        self.store = store
        self.helpers = helpers
        self.video = video
        self.quarantine = quarantine
        self.clock = clock
        self.settings = store.loadSettings()
        self.history = store.loadHistory()
        self.directory = Self.acceptedDirectory(settings.downloadDirectoryPath)
        self.phase = directory == nil ? .needsFolder : .starting
        self.message = directory == nil ? Self.chooseFolderMessage : nil
        self.tracked = Self.historyRows(history, root: directory)
        rebuild()
    }

    public static func missingHelperMessage(_ helpers: HelperStatus) -> String {
        var missing: [String] = []
        if !helpers.aria2Found {
            missing.append("aria2c")
        }
        if !helpers.watchFound {
            missing.append("umb-watch")
        }
        let names = missing.joined(separator: " and ")
        return "Missing \(names). Build aria2c with scripts/build-aria2.sh. "
            + "Release builds use Contents/Helpers only. "
            + "Debug builds also honor ARIA2C and UMB_WATCH."
    }

    public func updateDownloadDirectory(_ folder: URL) async throws {
        let previous = directory?.path
        let wasRunning = phase == .running
        try chooseDownloadDirectory(folder)
        let changed = directory?.path != previous
        if changed || !wasRunning {
            await start()
        }
    }

    public func checkedChildFolder(_ folder: URL) throws -> URL {
        guard let directory else {
            throw SessionError.folderMissing
        }
        return try DownloadFolderRules.acceptChild(folder, root: directory)
    }

    public func add(urlText: String, outputName: String, folder: URL?) async throws {
        guard let directory else {
            throw SessionError.folderMissing
        }
        guard let client else {
            throw SessionError.engineNotRunning
        }
        let prepared = try DownloadRequests.prepare(
            urlText: urlText,
            outputName: outputName,
            directory: folder,
            root: directory
        )
        let gid = try await client.add(url: prepared.url, options: prepared.options)
        tracked.insert(makeLiveItem(gid: gid, prepared: prepared), at: 0)
        setMessage(nil)
        rebuild()
    }

    /// Adds a handoff the user already confirmed. Options are rebuilt from the URL and file name.
    public func addExternal(_ download: ConfirmedExternalDownload) async throws {
        guard let directory else {
            throw SessionError.folderMissing
        }
        let checked = try ExternalDownload.confirm(
            ExtensionHandoff(
                uri: download.uri,
                outputName: download.outputName,
                url: download.url,
                kind: download.kind
            ),
            downloadRoot: directory
        )
        switch checked.kind {
        case .video:
            try await addVideo(
                urlText: checked.uri,
                outputName: checked.outputName ?? "",
                folder: nil
            )
        case .torrentFile:
            try await addLocalTorrent(checked, directory: directory)
        case .metalinkFile:
            try await importLocalMetalink(checked, directory: directory)
        case .download:
            if DownloadCaptureHint.isTorrent(url: checked.url, filename: checked.outputName) {
                try await addRemoteTorrent(checked, directory: directory)
            } else {
                try await addRemoteURI(checked, directory: directory)
            }
        }
    }

    public func pause(id: String) async {
        await change(
            id: id,
            allow: \.allowsPause,
            call: { client, gid in
                try await client.pause(gid: gid)
            },
            apply: { item in
                item.state = .paused
                item.downloadSpeed = 0
            }
        )
    }

    public func resume(id: String) async {
        await change(
            id: id,
            allow: \.allowsResume,
            call: { client, gid in
                try await client.resume(gid: gid)
            },
            apply: { item in
                item.state = .waiting
                item.downloadSpeed = 0
            }
        )
    }

    public func remove(id: String) async {
        videoJobs.removeValue(forKey: id)?.cancel()
        guard let index = index(of: id) else { return }
        if stopsInEngine(tracked[index]), let gid = tracked[index].engineGID, let client {
            do {
                try await client.remove(gid: gid)
            } catch {
                setMessage(DownloadMessage.text(for: error))
                rebuild()
                return
            }
        }
        let historyID = tracked[index].historyID
        tracked.remove(at: index)
        if let historyID {
            history.removeAll { $0.id == historyID }
            store.saveHistory(history)
        }
        setMessage(nil)
        rebuild()
    }

    public func start() async {
        guard let directory else {
            phase = .needsFolder
            setMessage(Self.chooseFolderMessage)
            rebuild()
            return
        }
        guard helpers.aria2Found, helpers.watchFound else {
            phase = .failed
            setMessage(Self.missingHelperMessage(helpers))
            rebuild()
            return
        }
        stopVideoProcesses()
        abandonLiveDownloads()
        phase = .starting
        setMessage(nil)
        rebuild()
        do {
            client = try await engine.start(downloadDirectory: directory)
            phase = .running
            setMessage(nil)
        } catch {
            client = nil
            phase = .failed
            setMessage(DownloadMessage.text(for: error))
        }
        rebuild()
    }

    public func stop() {
        stopVideoProcesses()
        markVideoStopped("Cancelled.")
        engine.stop()
        client = nil
        if phase == .running || phase == .starting {
            phase = .failed
            setMessage("The download engine is stopped.")
        }
        rebuild()
    }

    public func refresh() async {
        guard let client, phase == .running, !refreshing else { return }
        refreshing = true
        defer {
            refreshing = false
            rebuild()
        }
        // status() quarantines finished files, so refresh has to call it.
        let gids = liveGIDs()
        var failed = false
        for gid in gids {
            do {
                let status = try await client.status(gid: gid)
                if let index = indexOfLive(gid) {
                    apply(status, to: index)
                }
            } catch {
                failed = true
                message = DownloadMessage.text(for: error)
                refreshOwnsMessage = true
            }
        }
        refreshVideos()
        if !failed, refreshOwnsMessage {
            setMessage(nil)
        }
    }

    public func takeNotices() -> [DownloadNotice] {
        let pending = notices
        notices.removeAll()
        return pending
    }

    public func setNotifyOnComplete(_ enabled: Bool) {
        settings.notifyOnComplete = enabled
        store.saveSettings(settings)
        rebuild()
    }

    public func setNotifyOnFailure(_ enabled: Bool) {
        settings.notifyOnFailure = enabled
        store.saveSettings(settings)
        rebuild()
    }

    public func report(_ error: Error) {
        setMessage(DownloadMessage.text(for: error))
        rebuild()
    }
}
