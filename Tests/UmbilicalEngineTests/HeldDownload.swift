// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@testable import UmbilicalEngine

final class HeldTrial {
    var pcap = Data()
    var completedAt: TimeInterval = 0
    var graceEnd: TimeInterval = 0
    var postEnd: TimeInterval = 0
    var announced: [UInt16] = []
    var sockets: [[String]] = []
    var downloads = URL(fileURLWithPath: "/")
    var payload = Data()
    var quarantinePaths: [String] = []
    var global: [String: String] = [:]
    var log = ""
    var seederPort: UInt16 = 0
    var leecherPort: UInt16 = 0
    var seederHandshakes = 0
    var leecherHandshakes = 0
    var leecherReceived = 0
}

final class HeldRig {
    let tracker: LocalTracker
    let seeder: PiecePeer
    let leecher: PiecePeer
    let torrent: BuiltTorrent
    let payload: Data
    let capture: RunningCapture
    let downloads: URL
    let jobDirectory: URL
    let supervisor: EngineSupervisor
    let quarantine: RecordingQuarantine
    var client: RPCClient?

    init(
        tracker: LocalTracker,
        seeder: PiecePeer,
        leecher: PiecePeer,
        torrent: BuiltTorrent,
        payload: Data,
        capture: RunningCapture,
        downloads: URL,
        jobDirectory: URL,
        supervisor: EngineSupervisor,
        quarantine: RecordingQuarantine
    ) {
        self.tracker = tracker
        self.seeder = seeder
        self.leecher = leecher
        self.torrent = torrent
        self.payload = payload
        self.capture = capture
        self.downloads = downloads
        self.jobDirectory = jobDirectory
        self.supervisor = supervisor
        self.quarantine = quarantine
    }

    func stopAll() {
        capture.abandon()
        supervisor.stop()
        seeder.stop()
        leecher.stop()
        tracker.stop()
        try? FileManager.default.removeItem(at: downloads)
        try? FileManager.default.removeItem(at: jobDirectory)
    }

    func peerDebug() -> String {
        "hands seeder=\(seeder.handshakes) leecher=\(leecher.handshakes) "
            + "leecherBytes=\(leecher.receivedPieceBytes)"
    }
}

func makeHeldRig(aria2: URL) throws -> HeldRig {
    let payload = heldPayload()
    let tracker = try LocalTracker(injected: [])
    tracker.start()
    let announce = "http://127.0.0.1:\(tracker.port)/announce"
    let torrent = TorrentBuild.single(
        name: "payload.bin",
        payload: payload,
        pieceLength: 16_384,
        announce: announce
    )
    let seeder = try heldPeer(.seeder, torrent, BTWire.seederID, hold: 7)
    let leecher = try heldPeer(.leecher, torrent, BTWire.leecherID, hold: nil)
    seeder.start()
    leecher.start()
    tracker.inject(seeder.port)
    tracker.inject(leecher.port)
    let capture = try RunningCapture.start(ports: [seeder.port, leecher.port])
    let downloads = try makeTemporaryDirectory()
    let jobDirectory = try makeTemporaryDirectory()
    let quarantine = RecordingQuarantine()
    let supervisor = EngineSupervisor(
        aria2Executable: aria2,
        downloadDirectory: downloads,
        watchHelper: try TestBins.watchHelper(),
        quarantine: quarantine
    )
    return HeldRig(
        tracker: tracker,
        seeder: seeder,
        leecher: leecher,
        torrent: torrent,
        payload: payload,
        capture: capture,
        downloads: downloads,
        jobDirectory: jobDirectory,
        supervisor: supervisor,
        quarantine: quarantine
    )
}

func driveHeldDownload(_ rig: HeldRig) async throws -> HeldTrial {
    do {
        return try await driveHeldBody(rig)
    } catch {
        let secret = rig.client?.secret ?? ""
        let log = rig.supervisor.launchOutput(redacting: secret)
        throw TrialFailure(description: "\(error) \(rig.peerDebug()) aria2=\(log)")
    }
}

private func driveHeldBody(_ rig: HeldRig) async throws -> HeldTrial {
    let client = try await rig.supervisor.start()
    rig.client = client
    let trial = HeldTrial()
    trial.global = try await globalOptions(client)
    let gid = try await addHeldTorrent(rig, client)
    _ = try await waitForStatus(client, gid: gid, timeout: 30) {
        $0.completedLength >= 16_384
    }
    trial.sockets = try await collectSockets(rig)
    rig.seeder.releaseHold()
    _ = try await waitForStatus(client, gid: gid, timeout: 30) { $0.state == .complete }
    trial.completedAt = Date().timeIntervalSince1970
    try await Task.sleep(nanoseconds: 1_500_000_000)
    trial.graceEnd = Date().timeIntervalSince1970
    try await Task.sleep(nanoseconds: 3_000_000_000)
    trial.postEnd = Date().timeIntervalSince1970
    trial.pcap = try rig.capture.stop()
    fill(trial, rig, client)
    return trial
}

private func addHeldTorrent(_ rig: HeldRig, _ client: RPCClient) async throws -> String {
    let file = rig.jobDirectory.appendingPathComponent("job.torrent")
    try rig.torrent.bytes.write(to: file)
    return try await client.addTorrent(file: file)
}

private func fill(_ trial: HeldTrial, _ rig: HeldRig, _ client: RPCClient) {
    trial.downloads = rig.downloads
    trial.payload = rig.payload
    trial.announced = rig.tracker.announcedPorts()
    trial.quarantinePaths = rig.quarantine.paths
    trial.log = rig.supervisor.launchOutput(redacting: client.secret)
    trial.seederPort = rig.seeder.port
    trial.leecherPort = rig.leecher.port
    trial.seederHandshakes = rig.seeder.handshakes
    trial.leecherHandshakes = rig.leecher.handshakes
    trial.leecherReceived = rig.leecher.receivedPieceBytes
}

private func collectSockets(_ rig: HeldRig) async throws -> [[String]] {
    guard let root = rig.supervisor.processIdentifier else {
        throw TrialFailure(description: "aria2 was not running")
    }
    var samples: [[String]] = []
    let deadline = Date().addingTimeInterval(4)
    while Date() < deadline {
        samples.append(try ProcessSockets.establishedRemotes(root: root))
        try await Task.sleep(nanoseconds: 500_000_000)
    }
    return samples
}

private func heldPeer(
    _ role: PiecePeer.Role,
    _ torrent: BuiltTorrent,
    _ peerID: Data,
    hold: Int?
) throws -> PiecePeer {
    try PiecePeer(
        role: role,
        infoHash: torrent.infoHash,
        peerID: peerID,
        pieces: torrent.pieces,
        holdIndex: hold
    )
}

private func heldPayload() -> Data {
    var data = Data()
    for index in 0..<8 {
        data.append(Data(repeating: UInt8(index + 1), count: 16_384))
    }
    return data
}

private func globalOptions(_ client: RPCClient) async throws -> [String: String] {
    let transport = LoopbackTransport(port: client.port, timeoutSeconds: 5)
    let result = try await transport.call(
        method: "aria2.getGlobalOption",
        parameters: ["token:\(client.secret)"]
    )
    let object = result as? [String: Any] ?? [:]
    var map: [String: String] = [:]
    for (key, value) in object {
        if let text = value as? String {
            map[key] = text
        } else if let number = value as? NSNumber {
            map[key] = number.stringValue
        }
    }
    return map
}
