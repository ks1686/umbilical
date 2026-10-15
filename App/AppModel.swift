// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import SwiftUI
import UmbilicalUI

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var snapshot: SessionSnapshot

    private let session: DownloadSessionModel
    private var loop: Task<Void, Never>?

    init() {
        let located = AppHelpers.locate()
        let session = DownloadSessionModel(
            engine: ConfiguredEngine(aria2: located.aria2, watch: located.watch),
            store: UserDefaultsSettingsStore(defaults: .standard),
            helpers: located.status
        )
        self.session = session
        self.snapshot = session.snapshot
        AppTermination.model = self
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

    func add(urlText: String, outputName: String, folder: URL?) async throws {
        defer { publish() }
        try await session.add(urlText: urlText, outputName: outputName, folder: folder)
    }

    func pause(id: String) async {
        await session.pause(id: id)
        publish()
    }

    func resume(id: String) async {
        await session.resume(id: id)
        publish()
    }

    func remove(id: String) async {
        await session.remove(id: id)
        publish()
    }

    func start() async {
        await session.start()
        publish()
    }

    func stop() {
        loop?.cancel()
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

    private func run() async {
        await session.start()
        publish()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled {
                break
            }
            await session.refresh()
            publish()
        }
    }

    private func publish() {
        snapshot = session.snapshot
        for notice in session.takeNotices() {
            DownloadNotifier.post(notice)
        }
    }
}
