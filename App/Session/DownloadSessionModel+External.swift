// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalEngine

extension DownloadSessionModel {
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

    func addRemoteURI(_ download: ConfirmedExternalDownload, directory _: URL) async throws {
        guard let client else {
            throw SessionError.engineNotRunning
        }
        let prepared = PreparedDownload(url: download.url, options: download.options)
        let gid = try await client.add(url: prepared.url, options: prepared.options)
        tracked.insert(makeLiveItem(gid: gid, prepared: prepared), at: 0)
        setMessage(nil)
        rebuild()
    }

    func addRemoteTorrent(_ download: ConfirmedExternalDownload, directory: URL) async throws {
        guard let client else {
            throw SessionError.engineNotRunning
        }
        let destination = try await HandoffImport.fetchTorrent(
            url: download.url,
            filename: download.outputName,
            directory: directory
        )
        let gid = try await client.addTorrent(file: destination, options: [:])
        let prepared = PreparedDownload(url: download.url, options: [:])
        tracked.insert(makeLiveItem(gid: gid, prepared: prepared), at: 0)
        setMessage(nil)
        rebuild()
    }

    func addLocalTorrent(_ download: ConfirmedExternalDownload, directory: URL) async throws {
        guard let client else {
            throw SessionError.engineNotRunning
        }
        let destination = try HandoffImport.copyLocal(
            url: download.url,
            filename: download.outputName,
            directory: directory,
            torrent: true
        )
        let gid = try await client.addTorrent(file: destination, options: [:])
        let prepared = PreparedDownload(url: download.url, options: download.options)
        tracked.insert(makeLiveItem(gid: gid, prepared: prepared), at: 0)
        setMessage(nil)
        rebuild()
    }

    func importLocalMetalink(_ download: ConfirmedExternalDownload, directory: URL) async throws {
        let destination = try HandoffImport.copyLocal(
            url: download.url,
            filename: download.outputName,
            directory: directory,
            torrent: false
        )
        try quarantine.markDownloaded(file: destination)
        let size = fileSize(destination)
        let name = destination.lastPathComponent
        let item = TrackedDownload(
            id: "import-\(UUID().uuidString)",
            engineGID: nil,
            track: false,
            outputName: name,
            url: download.url,
            detail: destination.path,
            state: .complete,
            totalLength: size,
            completedLength: size,
            downloadSpeed: 0,
            errorMessage: nil,
            filePath: destination.path,
            historyID: nil,
            fixedTitle: name,
            pausable: false
        )
        tracked.insert(item, at: 0)
        finish(0)
        setMessage(nil)
        rebuild()
    }

    private func fileSize(_ url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize {
            return Int64(size)
        }
        return 0
    }
}
