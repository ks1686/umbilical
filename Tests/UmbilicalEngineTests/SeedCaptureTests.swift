// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import XCTest

final class SeedCaptureTests: XCTestCase {
    func testUploadStopsAfterCompletionAndStaysCapped() async throws {
        FileHandle.standardError.write(Data("SeedCapture: begin\n".utf8))
        let aria2 = try TestBins.requireAria2()
        let rig = try makeHeldRig(aria2: aria2)
        defer { rig.stopAll() }
        let trial = try await driveHeldDownload(rig)
        let events = try loadBitTorrentEvents(trial.pcap)
        let failures = testRun?.failureCount ?? 0
        try assertUploadCeiling(trial, events)
        assertSilentAfterGrace(trial, events)
        assertLoopback(trial)
        try assertPayload(trial)
        assertGlobalCaps(trial)
        if (testRun?.failureCount ?? 0) == failures {
            noteSeedCapturePass()
        }
    }

    private func noteSeedCapturePass() {
        let line = "SeedCapture: ran on \(captureInterface()), PASS\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}

private func loadBitTorrentEvents(_ pcap: Data) throws -> [BTEvent] {
    let conversations = try CaptureParser.conversations(in: pcap)
    if conversations.isEmpty {
        throw TrialFailure(description: "packet capture had no TCP conversations")
    }
    var events: [BTEvent] = []
    var sawSYN = false
    for conversation in conversations {
        guard let parsed = try CaptureParser.bitTorrentEvents(in: conversation) else {
            continue
        }
        if parsed.isEmpty {
            continue
        }
        if !conversation.sawSYN {
            throw TrialFailure(description: "BitTorrent flow had no SYN")
        }
        sawSYN = true
        events.append(contentsOf: parsed)
    }
    if !sawSYN || events.isEmpty {
        throw TrialFailure(description: "packet capture had no BitTorrent payload")
    }
    return events
}

private func assertUploadCeiling(_ trial: HeldTrial, _ events: [BTEvent]) throws {
    let engine = events.filter {
        isEnginePiece($0, trial: trial) && $0.time <= trial.completedAt
    }
    let bytes = engine.reduce(0) { $0 + $1.pieceBytes }
    let start = engine.map(\.time).min() ?? trial.completedAt
    let duration = max(0, trial.completedAt - start)
    let ceiling = Int((1024.0 * duration).rounded(.up)) + 16_384 + 4096
    if bytes < 512 {
        XCTFail("engine uploaded \(bytes) piece bytes while incomplete. \(heldDebug(trial))")
    }
    XCTAssertLessThanOrEqual(bytes, ceiling, heldDebug(trial))
    let seeded = events.filter { $0.kind == .piece && $0.source.port == trial.seederPort }
        .reduce(0) { $0 + $1.pieceBytes }
    XCTAssertGreaterThanOrEqual(seeded, 16_384, heldDebug(trial))
}

private func assertSilentAfterGrace(_ trial: HeldTrial, _ events: [BTEvent]) {
    let late = events.filter {
        isEnginePiece($0, trial: trial) && $0.time >= trial.graceEnd
    }.reduce(0) { $0 + $1.pieceBytes }
    XCTAssertEqual(late, 0, heldDebug(trial))
    let requests = events.filter {
        $0.kind == .request && $0.source.port == trial.leecherPort
    }
    let latest = requests.map(\.time).max() ?? 0
    XCTAssertFalse(requests.isEmpty, heldDebug(trial))
    XCTAssertGreaterThanOrEqual(
        latest,
        trial.completedAt - 2,
        "leecher stopped requesting before completion. \(heldDebug(trial))"
    )
}

private func assertLoopback(_ trial: HeldTrial) {
    let remotes = trial.sockets.flatMap { $0 }
    XCTAssertFalse(remotes.isEmpty, "no established TCP during the download. \(heldDebug(trial))")
    for remote in remotes {
        XCTAssertTrue(remote == "127.0.0.1" || remote == "::1", "remote \(remote)")
    }
}

private func assertPayload(_ trial: HeldTrial) throws {
    let saved = trial.downloads.appendingPathComponent("payload.bin")
    XCTAssertEqual(try Data(contentsOf: saved), trial.payload)
    XCTAssertFalse(trial.quarantinePaths.isEmpty)
}

private func assertGlobalCaps(_ trial: HeldTrial) {
    XCTAssertEqual(trial.global["seed-time"], "0")
    let upload = trial.global["max-upload-limit"] ?? ""
    XCTAssertTrue(upload == "1K" || upload == "1024", "max-upload-limit=\(upload)")
    let ratio = trial.global["seed-ratio"] ?? ""
    XCTAssertFalse(ratio == "0" || ratio == "0.0", "seed-ratio=\(ratio)")
    XCTAssertEqual(trial.global["follow-torrent"], "false")
    XCTAssertEqual(trial.global["follow-metalink"], "false")
}

private func isEnginePiece(_ event: BTEvent, trial: HeldTrial) -> Bool {
    guard event.kind == .piece, event.pieceBytes > 0 else {
        return false
    }
    let peers: Set<UInt16> = [trial.seederPort, trial.leecherPort]
    if peers.contains(event.destination.port) {
        return true
    }
    return Set(trial.announced).contains(event.source.port)
}

private func heldDebug(_ trial: HeldTrial) -> String {
    "hands seeder=\(trial.seederHandshakes) leecher=\(trial.leecherHandshakes) "
        + "leecherBytes=\(trial.leecherReceived) aria2=\(trial.log)"
}
