// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

@testable import UmbilicalEngine

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class TorrentDownloadTests: XCTestCase {
    func testSelectFileDownloadsOnlyTheFirstFile() async throws {
        let aria2 = try TestBins.requireAria2()
        let swarm = try startSelectSwarm()
        defer { swarm.stop() }
        let engine = try await startDownloadEngine(aria2: aria2)
        defer { engine.stop() }
        try await finishSelectFile(swarm, engine)
    }

    func testMagnetDownloadsFromASeedingAria2() async throws {
        let aria2 = try TestBins.requireAria2()
        let seeded = try startMagnetSeeder(aria2: aria2)
        defer { seeded.stop() }
        let engine = try await startDownloadEngine(aria2: aria2)
        defer { engine.stop() }
        try await finishMagnet(seeded, engine)
    }
}

struct DownloadEngine {
    var supervisor: EngineSupervisor
    var client: RPCClient
    var downloads: URL

    func stop() {
        supervisor.stop()
        try? FileManager.default.removeItem(at: downloads)
    }
}

func startDownloadEngine(aria2: URL) async throws -> DownloadEngine {
    let downloads = try makeTemporaryDirectory()
    let supervisor = EngineSupervisor(
        aria2Executable: aria2,
        downloadDirectory: downloads,
        watchHelper: try TestBins.watchHelper(),
        quarantine: RecordingQuarantine()
    )
    do {
        let client = try await supervisor.start()
        return DownloadEngine(supervisor: supervisor, client: client, downloads: downloads)
    } catch {
        supervisor.stop()
        try? FileManager.default.removeItem(at: downloads)
        throw error
    }
}

private struct SelectSwarm {
    var tracker: LocalTracker
    var seeder: PiecePeer
    var torrent: BuiltTorrent
    var first: Data
    var directory: URL

    func stop() {
        seeder.stop()
        tracker.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func startSelectSwarm() throws -> SelectSwarm {
    let tracker = try LocalTracker(injected: [])
    tracker.start()
    let first = Data(repeating: 0x11, count: 16_384)
    let second = Data(repeating: 0x22, count: 16_384)
    let announce = "http://127.0.0.1:\(tracker.port)/announce"
    let torrent = TorrentBuild.multiple(
        directory: "bundle",
        files: [
            TorrentBuild.FileSpec(components: ["a.bin"], bytes: first),
            TorrentBuild.FileSpec(components: ["b.bin"], bytes: second)
        ],
        pieceLength: 16_384,
        announce: announce
    )
    let seeder = try PiecePeer(
        role: .seeder,
        infoHash: torrent.infoHash,
        peerID: BTWire.seederID,
        pieces: torrent.pieces,
        holdIndex: nil
    )
    seeder.start()
    tracker.inject(seeder.port)
    let directory = try makeTemporaryDirectory()
    let file = directory.appendingPathComponent("job.torrent")
    try torrent.bytes.write(to: file)
    return SelectSwarm(
        tracker: tracker,
        seeder: seeder,
        torrent: torrent,
        first: first,
        directory: directory
    )
}

private func finishSelectFile(_ swarm: SelectSwarm, _ engine: DownloadEngine) async throws {
    let file = swarm.directory.appendingPathComponent("job.torrent")
    do {
        let gid = try await engine.client.addTorrent(file: file, options: ["select-file": "1"])
        _ = try await waitForStatus(engine.client, gid: gid, timeout: 30) {
            $0.state == .complete
        }
        let saved = engine.downloads.appendingPathComponent("bundle/a.bin")
        let other = engine.downloads.appendingPathComponent("bundle/b.bin")
        XCTAssertEqual(try Data(contentsOf: saved), swarm.first)
        if FileManager.default.fileExists(atPath: other.path) {
            XCTAssertEqual(try Data(contentsOf: other).count, 0)
        }
    } catch {
        let log = engine.supervisor.launchOutput(redacting: engine.client.secret)
        XCTFail("select-file failed: \(error) hands=\(swarm.seeder.handshakes) aria2=\(log)")
    }
}

private struct MagnetSeed {
    var tracker: LocalTracker
    var seeder: Aria2Seeder
    var payload: Data
    var magnet: String
    var directory: URL

    func stop() {
        seeder.stop()
        tracker.stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func startMagnetSeeder(aria2: URL) throws -> MagnetSeed {
    let tracker = try LocalTracker(injected: [])
    tracker.start()
    let payload = Data(repeating: 0x5A, count: 32 * 1024)
    let announce = "http://127.0.0.1:\(tracker.port)/announce"
    let torrent = TorrentBuild.single(
        name: "magnet.bin",
        payload: payload,
        pieceLength: 16_384,
        announce: announce
    )
    let directory = try makeTemporaryDirectory()
    try payload.write(to: directory.appendingPathComponent("magnet.bin"))
    let file = directory.appendingPathComponent("job.torrent")
    try torrent.bytes.write(to: file)
    let listen = try POSIX.freeLoopbackPort()
    let seeder = try Aria2Seeder(
        aria2: aria2,
        directory: directory,
        torrent: file,
        listenPort: listen
    )
    try seeder.start()
    try waitForAnnounced(tracker, listen)
    let magnet = "magnet:?xt=urn:btih:\(TorrentBuild.hex(torrent.infoHash))&tr=\(announce)"
    return MagnetSeed(
        tracker: tracker,
        seeder: seeder,
        payload: payload,
        magnet: magnet,
        directory: directory
    )
}

private func finishMagnet(_ seeded: MagnetSeed, _ engine: DownloadEngine) async throws {
    let global = try await globalOptions(engine.client)
    XCTAssertEqual(global["follow-torrent"], "false")
    do {
        let gid = try await engine.client.add(url: try testURL(seeded.magnet))
        _ = try await waitForStatus(engine.client, gid: gid, timeout: 40) {
            $0.state == .complete
        }
        let saved = engine.downloads.appendingPathComponent("magnet.bin")
        XCTAssertEqual(try Data(contentsOf: saved), seeded.payload)
    } catch {
        let log = engine.supervisor.launchOutput(redacting: engine.client.secret)
        let follow = global["follow-torrent"] ?? ""
        XCTFail(
            "magnet failed: \(error) follow-torrent=\(follow) "
                + "seeder=\(seeded.seeder.output()) aria2=\(log)"
        )
    }
}

private func waitForAnnounced(_ tracker: LocalTracker, _ port: UInt16) throws {
    let deadline = Date().addingTimeInterval(15)
    while Date() < deadline {
        if tracker.announcedPorts().contains(port) {
            return
        }
        usleep(50_000)
    }
    throw FixtureError.timedOut
}
