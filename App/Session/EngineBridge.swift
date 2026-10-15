// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import UmbilicalEngine

public protocol DownloadControlling: AnyObject {
    func add(url: URL, options: [String: String]) async throws -> String
    func pause(gid: String) async throws
    func resume(gid: String) async throws
    func remove(gid: String) async throws
    func status(gid: String) async throws -> DownloadStatus
}

extension RPCClient: DownloadControlling {}

public protocol EngineLaunching: AnyObject {
    func start(downloadDirectory: URL) async throws -> any DownloadControlling
    func stop()
}

public final class ConfiguredEngine: EngineLaunching {
    private let aria2: URL?
    private let watch: URL?
    private var live: LiveEngine?

    public init(aria2: URL?, watch: URL?) {
        self.aria2 = aria2
        self.watch = watch
    }

    public func start(downloadDirectory: URL) async throws -> any DownloadControlling {
        guard let aria2 else {
            throw EngineError.executableMissing("aria2c")
        }
        guard let watch else {
            throw EngineError.executableMissing("umb-watch")
        }
        stop()
        let engine = LiveEngine(aria2Executable: aria2, watchHelper: watch)
        let client = try await engine.start(downloadDirectory: downloadDirectory)
        live = engine
        return client
    }

    public func stop() {
        live?.stop()
        live = nil
    }
}

final class LiveEngine: EngineLaunching {
    private let aria2Executable: URL
    private let watchHelper: URL
    private var supervisor: EngineSupervisor?

    init(aria2Executable: URL, watchHelper: URL) {
        self.aria2Executable = aria2Executable
        self.watchHelper = watchHelper
    }

    func start(downloadDirectory: URL) async throws -> any DownloadControlling {
        stop()
        let supervisor = EngineSupervisor(
            aria2Executable: aria2Executable,
            downloadDirectory: downloadDirectory,
            watchHelper: watchHelper
        )
        do {
            let client = try await supervisor.start()
            self.supervisor = supervisor
            return client
        } catch {
            supervisor.stop()
            throw error
        }
    }

    func stop() {
        supervisor?.stop()
        supervisor = nil
    }
}
