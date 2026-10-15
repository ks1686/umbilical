// SPDX-License-Identifier: GPL-3.0-or-later

import XCTest

@testable import UmbilicalEngine

final class CaptureParserTests: XCTestCase {
    func testLinuxCookedCaptureReassemblesPiecePayload() throws {
        let payload = handshakeBytes() + pieceBytes()
        let syn = ipv4tcp(src: 40000, dst: 6881, seq: 1000, flags: 0x02, payload: [])
        let data = ipv4tcp(src: 40000, dst: 6881, seq: 1001, flags: 0x18, payload: payload)
        let pcap = littleEndianPcap([sll2(syn), sll2(data)])
        let conversations = try CaptureParser.conversations(in: pcap)
        let flow = try XCTUnwrap(conversations.first)
        XCTAssertEqual(conversations.count, 1)
        XCTAssertTrue(flow.sawSYN)
        XCTAssertEqual(flow.destination.port, 6881)
        let events = try XCTUnwrap(try CaptureParser.bitTorrentEvents(in: flow))
        XCTAssertEqual(events.map(\.kind), [.handshake, .piece])
        XCTAssertEqual(events[1].pieceBytes, 4)
    }

    func testCaptureFailureNamesTheUnverifiedClaim() {
        let text = CaptureUnavailable().description
        XCTAssertTrue(text.contains("Not verified"))
        XCTAssertTrue(text.contains("piece payload stops after completion"))
        XCTAssertTrue(text.contains("1K cap"))
        XCTAssertTrue(text.contains("seed-time=0"))
        XCTAssertTrue(text.contains("max-upload-limit=1K"))
        XCTAssertTrue(text.contains("seed-ratio unset"))
    }

    func testTrackerBodyIsSortedBencode() throws {
        let body = LocalTracker.body(ports: [1, 80])
        let parsed = try BEncodeParser.parse(body)
        XCTAssertEqual(parsed.lookup("interval")?.integer, 1)
        XCTAssertEqual(parsed.lookup("min interval")?.integer, 1)
        XCTAssertEqual(parsed.lookup("peers")?.bytes?.count, 12)
    }
}

private func littleEndianPcap(_ packets: [[UInt8]]) -> Data {
    var bytes: [UInt8] = [
        0xD4, 0xC3, 0xB2, 0xA1,
        0x02, 0x00, 0x04, 0x00,
        0, 0, 0, 0,
        0, 0, 0, 0,
        0xFF, 0xFF, 0, 0,
        0x14, 0x01, 0, 0
    ]
    for (index, packet) in packets.enumerated() {
        bytes.append(contentsOf: le32(1_700_000_000))
        bytes.append(contentsOf: le32(UInt32(index * 1000)))
        bytes.append(contentsOf: le32(UInt32(packet.count)))
        bytes.append(contentsOf: le32(UInt32(packet.count)))
        bytes.append(contentsOf: packet)
    }
    return Data(bytes)
}

private func sll2(_ ip: [UInt8]) -> [UInt8] {
    var header = [UInt8](repeating: 0, count: 20)
    header[0] = 0x08
    header[1] = 0x00
    return header + ip
}

private func ipv4tcp(
    src: UInt16,
    dst: UInt16,
    seq: UInt32,
    flags: UInt8,
    payload: [UInt8]
) -> [UInt8] {
    let total = 40 + payload.count
    var packet: [UInt8] = [
        0x45, 0, UInt8(total >> 8), UInt8(total & 0xFF),
        0, 0, 0, 0,
        64, 6, 0, 0,
        127, 0, 0, 1,
        127, 0, 0, 1
    ]
    packet.append(contentsOf: be16(src))
    packet.append(contentsOf: be16(dst))
    packet.append(contentsOf: be32(seq))
    packet.append(contentsOf: be32(0))
    packet.append(0x50)
    packet.append(flags)
    packet.append(contentsOf: [0xFF, 0xFF, 0, 0, 0, 0])
    packet.append(contentsOf: payload)
    return packet
}

private func handshakeBytes() -> [UInt8] {
    var bytes: [UInt8] = [19]
    bytes.append(contentsOf: Array("BitTorrent protocol".utf8))
    bytes.append(contentsOf: [UInt8](repeating: 0, count: 48))
    return bytes
}

private func pieceBytes() -> [UInt8] {
    var bytes = be32(13)
    bytes.append(7)
    bytes.append(contentsOf: be32(0))
    bytes.append(contentsOf: be32(0))
    bytes.append(contentsOf: [1, 2, 3, 4])
    return bytes
}

private func le32(_ value: UInt32) -> [UInt8] {
    [
        UInt8(value & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 24) & 0xFF)
    ]
}

private func be16(_ value: UInt16) -> [UInt8] {
    [UInt8(value >> 8), UInt8(value & 0xFF)]
}

private func be32(_ value: UInt32) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ]
}
