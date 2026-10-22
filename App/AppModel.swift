// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI
import UmbilicalEngine
import UmbilicalUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: SessionSnapshot
    @Published private(set) var license: LicenseSnapshot
    @Published private(set) var stagedHandoff: StagedHandoff?
    @Published private(set) var handoffError: String?
    let safariNotice: SafariExtensionNoticeController

    private let session: DownloadSessionModel
    private let licensing: LicenseService
    private var loop: Task<Void, Never>?
    private var licenseStartup: Task<Void, Never>?
    private var licenseLaunched = false
    private var lastExternalURL = ""
    private var lastExternalAt = Date.distantPast
    private var handoffQueue = HandoffConfirmQueue<StagedHandoff>()

    init() {
        let located = AppHelpers.locate()
        let session = DownloadSessionModel(
            engine: ConfiguredEngine(aria2: located.aria2, watch: located.watch),
            store: UserDefaultsSettingsStore(defaults: .standard),
            helpers: located.status,
            video: VideoHelpers(ytDlp: located.ytDlp, watch: located.watch)
        )
        self.session = session
        let licensing = LicenseEnvironment.make()
        self.licensing = licensing
        self.snapshot = session.snapshot
        self.license = licensing.snapshot
        let version =
            Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? ""
        let safariNotice = SafariExtensionNoticeController(currentVersion: version)
        self.safariNotice = safariNotice
        AppTermination.attach(self)
        SafariExtensionBridge.refresh(safariNotice)
        loop = Task { @MainActor [weak self] in
            await self?.run()
        }
    }

    var downloadDirectory: URL? {
        guard let path = snapshot.downloadDirectoryPath else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func useRoot(_ folder: URL) async -> String? {
        do {
            try await session.updateDownloadDirectory(folder)
        } catch {
            session.report(error)
            publish()
            return DownloadMessage.text(for: error)
        }
        publish()
        if session.snapshot.phase == .failed {
            return session.snapshot.message
        }
        return nil
    }

    func checkedChildFolder(_ folder: URL) throws -> URL {
        try session.checkedChildFolder(folder)
    }

    var licenseAllowsNewDownloads: Bool {
        LicensePermissions.resolve(license.status).allowsNewDownloads
    }

    var licenseAllowsResume: Bool {
        LicensePermissions.resolve(license.status).allowsResume
    }

    func add(urlText: String, outputName: String, folder: URL?, video: Bool = false) async throws {
        try requireNewDownload()
        defer { publish() }
        if video {
            try await session.addVideo(urlText: urlText, outputName: outputName, folder: folder)
        } else {
            try await session.add(urlText: urlText, outputName: outputName, folder: folder)
        }
    }

    func pause(id: String) async {
        await session.pause(id: id)
        publish()
    }

    func resume(id: String) async {
        guard licenseAllowsResume else { return }
        await session.resume(id: id)
        publish()
    }

    func remove(id: String) async {
        await session.remove(id: id)
        publish()
    }

    func refreshSafariNotice() {
        SafariExtensionBridge.refresh(safariNotice)
    }

    func start() async {
        await session.start()
        publish()
    }

    func stop() {
        loop?.cancel()
        licenseStartup?.cancel()
        session.stop()
        publish()
    }

    func setNotifyOnComplete(_ enabled: Bool) {
        session.setNotifyOnComplete(enabled)
        publish()
    }

    func setNotifyOnFailure(_ enabled: Bool) {
        session.setNotifyOnFailure(enabled)
        publish()
    }

    func activateLicense(_ rawKey: String) async -> Bool {
        licensing.clearActionError()
        publish()
        await licensing.activate(rawKey)
        publish()
        guard license.actionError == nil else { return false }
        return licenseAllowsNewDownloads
    }

    func deactivateLicense() async {
        licensing.clearActionError()
        publish()
        await licensing.deactivate()
        publish()
    }

    func clearLicenseError() {
        guard license.actionError != nil || license.actionNotice != nil else { return }
        licensing.clearActionError()
        publish()
    }

    private func requireNewDownload() throws {
        guard licenseAllowsNewDownloads else {
            throw LicenseBlocked(message: LicenseCopy.actionBlocked)
        }
    }

    private func run() async {
        await session.start()
        publish()
        licenseStartup = Task { @MainActor [weak self] in
            await self?.licensing.launch()
            guard let self, !Task.isCancelled else { return }
            self.licenseLaunched = true
            self.publish()
        }
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled {
                break
            }
            await session.refresh()
            if licenseLaunched {
                await licensing.tick()
            }
            publish()
        }
    }

    private func publish() {
        license = licensing.snapshot
        snapshot = session.snapshot
        for notice in session.takeNotices() {
            DownloadNotifier.post(notice)
        }
    }
}

extension AppModel {
    func receiveExternalURL(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        let allowed =
            scheme == ExternalDownload.scheme
            || scheme == "magnet"
            || scheme == "http"
            || scheme == "https"
            || scheme == "ftp"
            || scheme == "sftp"
            || url.isFileURL
        guard allowed else { return }
        let key = url.absoluteString
        let now = Date()
        if key == lastExternalURL, now.timeIntervalSince(lastExternalAt) < 2 {
            return
        }
        lastExternalURL = key
        lastExternalAt = now
        let root =
            downloadDirectory
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        do {
            let handoff = try ExternalDownload.stage(openURL: url, downloadRoot: root)
            let staged = StagedHandoff(handoff: handoff)
            let showing = stagedHandoff != nil
            switch handoffQueue.enqueue(staged) {
            case .accepted:
                stagedHandoff = handoffQueue.current
                if !showing {
                    handoffError = nil
                }
            case .overflow:
                MacActions.presentRejectedDownload(
                    HandoffConfirmQueue<StagedHandoff>.overflowMessage,
                    onDismiss: {}
                )
            }
        } catch {
            let text = DownloadMessage.text(for: error)
            if stagedHandoff == nil {
                reportHandoffFailure(text)
            } else {
                MacActions.presentRejectedDownload(text) {}
            }
        }
        MacActions.activate()
    }

    func confirmStagedHandoff() async {
        guard let staged = stagedHandoff else { return }
        guard licenseAllowsNewDownloads else {
            reportHandoffFailure(LicenseCopy.actionBlocked)
            publish()
            return
        }
        guard let root = downloadDirectory else {
            reportHandoffFailure(DownloadMessage.text(for: SessionError.folderMissing))
            return
        }
        do {
            let confirmed = try ExternalDownload.confirm(staged.handoff, downloadRoot: root)
            try await session.addExternal(confirmed)
            if stagedHandoff?.id == staged.id {
                finishCurrentHandoff()
            }
        } catch {
            reportHandoffFailure(DownloadMessage.text(for: error))
        }
        publish()
    }

    func declineStagedHandoff() {
        finishCurrentHandoff()
    }

    func presentNextStagedHandoff() {
        handoffQueue.presentNextIfIdle()
        stagedHandoff = handoffQueue.current
        if stagedHandoff != nil {
            handoffError = nil
        }
    }

    func clearHandoffError() {
        handoffError = nil
    }

    private func finishCurrentHandoff() {
        handoffError = nil
        handoffQueue.clearCurrent()
        stagedHandoff = nil
    }

    private func reportHandoffFailure(_ text: String) {
        handoffError = text
        guard stagedHandoff == nil else {
            return
        }
        MacActions.presentRejectedDownload(text) { [weak self] in
            self?.clearHandoffError()
        }
    }
}
