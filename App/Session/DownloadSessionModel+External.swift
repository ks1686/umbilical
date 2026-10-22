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
            try await addLocalMetalink(checked, directory: directory)
        case .download:
            if DownloadCaptureHint.isTorrent(url: checked.url, filename: checked.outputName) {
                try await addRemoteTorrent(checked, directory: directory)
            } else if DownloadCaptureHint.isMetalink(
                url: checked.url,
                filename: checked.outputName
            ) {
                try await addRemoteMetalink(checked, directory: directory)
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

    func addRemoteTorrent(_ download: ConfirmedExternalDownload, directory _: URL) async throws {
        guard let client else {
            throw SessionError.engineNotRunning
        }
        let staged = try await HandoffImport.fetchTorrent(
            url: download.url,
            filename: download.outputName
        )
        defer { removePrivateStaging(staged) }
        let gid = try await client.addTorrent(file: staged, options: [:])
        let prepared = PreparedDownload(url: download.url, options: [:])
        tracked.insert(makeLiveItem(gid: gid, prepared: prepared), at: 0)
        setMessage(nil)
        rebuild()
    }

    func addLocalTorrent(_ download: ConfirmedExternalDownload, directory _: URL) async throws {
        guard let client else {
            throw SessionError.engineNotRunning
        }
        let gid = try await client.addTorrent(file: download.url, options: [:])
        let prepared = PreparedDownload(url: download.url, options: download.options)
        tracked.insert(makeLiveItem(gid: gid, prepared: prepared), at: 0)
        setMessage(nil)
        rebuild()
    }

    func addLocalMetalink(_ download: ConfirmedExternalDownload, directory _: URL) async throws {
        try await startMetalink(file: download.url, source: download.url)
    }

    func addRemoteMetalink(_ download: ConfirmedExternalDownload, directory: URL) async throws {
        let staged = try await HandoffImport.fetchMetalink(
            url: download.url,
            filename: download.outputName,
            downloadRoot: directory
        )
        defer { removePrivateStaging(staged) }
        try await startMetalink(file: staged, source: download.url)
    }

    private func startMetalink(file: URL, source: URL) async throws {
        guard let client else {
            throw SessionError.engineNotRunning
        }
        let options = ["follow-metalink": "true"]
        let gids = try await client.addMetalink(file: file, options: options)
        let name = source.lastPathComponent
        for gid in gids.reversed() {
            let prepared = PreparedDownload(
                url: source,
                options: name.isEmpty ? [:] : ["out": name]
            )
            tracked.insert(makeLiveItem(gid: gid, prepared: prepared), at: 0)
        }
        setMessage(nil)
        rebuild()
    }

    private func removePrivateStaging(_ file: URL) {
        try? FileManager.default.removeItem(at: file.deletingLastPathComponent())
    }
}
