// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

struct Endpoint: Hashable {
    var address: String
    var port: UInt16
}

struct TCPConversation {
    var source: Endpoint
    var destination: Endpoint
    var sawSYN: Bool
    var payload: [UInt8]
    var times: [TimeInterval]
}

enum BTKind {
    case handshake
    case piece
    case request
}

struct BTEvent {
    var kind: BTKind
    var time: TimeInterval
    var source: Endpoint
    var destination: Endpoint
    var pieceBytes: Int
}

enum CaptureParseError: Error, CustomStringConvertible {
    case truncated
    case gap
    case unsupportedLink(UInt32)
    case unparsed

    var description: String {
        switch self {
        case .truncated:
            return "packet capture was truncated"
        case .gap:
            return "packet capture missed TCP payload"
        case .unsupportedLink(let kind):
            return "packet capture link type \(kind) is not supported"
        case .unparsed:
            return "packet capture had a payload that was not parsed"
        }
    }
}

enum CaptureParser {
    static func conversations(in pcap: Data) throws -> [TCPConversation] {
        let bytes = [UInt8](pcap)
        let header = try headerInfo(bytes)
        var flows: [FlowKey: FlowBuild] = [:]
        var offset = 24
        while offset + 16 <= bytes.count {
            let stamp = timestamp(bytes, offset, header)
            let included = Int(CaptureLink.readU32(bytes, offset + 8, header.swap))
            let start = offset + 16
            let end = start + included
            if end > bytes.count {
                throw CaptureParseError.truncated
            }
            if let packet = try CaptureLink.packet(Array(bytes[start..<end]), link: header.link) {
                try addPacket(packet, time: stamp, flows: &flows)
            }
            offset = end
        }
        return try flows.map { key, flow in
            try flow.conversation(source: key.source, destination: key.destination)
        }
    }

    static func bitTorrentEvents(in conversation: TCPConversation) throws -> [BTEvent]? {
        let bytes = conversation.payload
        if bytes.isEmpty {
            return []
        }
        guard isHandshake(bytes) else {
            return nil
        }
        var events = [
            event(.handshake, conversation.times[0], conversation, 0)
        ]
        var offset = 68
        while offset + 4 <= bytes.count {
            let length = Int(CaptureLink.u32(bytes, offset))
            if length == 0 {
                offset += 4
                continue
            }
            let total = 4 + length
            if length > 128 * 1024 || offset + total > bytes.count {
                throw CaptureParseError.truncated
            }
            if let message = try messageEvent(bytes, offset, length, conversation) {
                events.append(message)
            }
            offset += total
        }
        if offset != bytes.count {
            throw CaptureParseError.truncated
        }
        return events
    }

    private static func messageEvent(
        _ bytes: [UInt8],
        _ offset: Int,
        _ length: Int,
        _ conversation: TCPConversation
    ) throws -> BTEvent? {
        let id = bytes[offset + 4]
        if id == 7 {
            let size = length - 9
            if size < 0 {
                throw CaptureParseError.truncated
            }
            let time = size == 0 ? conversation.times[offset] : conversation.times[offset + 13]
            return event(.piece, time, conversation, size)
        }
        if id == 6 {
            return event(.request, conversation.times[offset], conversation, 0)
        }
        return nil
    }

    private static func event(
        _ kind: BTKind,
        _ time: TimeInterval,
        _ conversation: TCPConversation,
        _ pieceBytes: Int
    ) -> BTEvent {
        BTEvent(
            kind: kind,
            time: time,
            source: conversation.source,
            destination: conversation.destination,
            pieceBytes: pieceBytes
        )
    }

    private static func isHandshake(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 68, bytes[0] == 19 else {
            return false
        }
        return Data(bytes[1..<20]) == Data("BitTorrent protocol".utf8)
    }
}

private struct PcapHeader {
    var swap: Bool
    var nano: Bool
    var link: UInt32
}

private struct FlowKey: Hashable {
    var source: Endpoint
    var destination: Endpoint
}

private struct Segment {
    var sequence: UInt32
    var time: TimeInterval
    var bytes: [UInt8]
}

private struct FlowBuild {
    var syn: UInt32?
    var segments: [Segment] = []

    func conversation(source: Endpoint, destination: Endpoint) throws -> TCPConversation {
        let assembled = try assemble(segments, syn: syn)
        return TCPConversation(
            source: source,
            destination: destination,
            sawSYN: syn != nil,
            payload: assembled.payload,
            times: assembled.times
        )
    }
}

private func headerInfo(_ bytes: [UInt8]) throws -> PcapHeader {
    if bytes.count < 24 {
        throw CaptureParseError.truncated
    }
    let magic = Array(bytes[0..<4])
    let littleMicro: [UInt8] = [0xD4, 0xC3, 0xB2, 0xA1]
    let bigMicro: [UInt8] = [0xA1, 0xB2, 0xC3, 0xD4]
    let littleNano: [UInt8] = [0x4D, 0x3C, 0xB2, 0xA1]
    let bigNano: [UInt8] = [0xA1, 0xB2, 0x3C, 0x4D]
    let swap: Bool
    let nano: Bool
    switch magic {
    case littleMicro:
        swap = false
        nano = false
    case bigMicro:
        swap = true
        nano = false
    case littleNano:
        swap = false
        nano = true
    case bigNano:
        swap = true
        nano = true
    default:
        throw CaptureParseError.truncated
    }
    return PcapHeader(swap: swap, nano: nano, link: CaptureLink.readU32(bytes, 20, swap))
}

private func timestamp(_ bytes: [UInt8], _ offset: Int, _ header: PcapHeader) -> TimeInterval {
    let seconds = Double(CaptureLink.readU32(bytes, offset, header.swap))
    let fraction = Double(CaptureLink.readU32(bytes, offset + 4, header.swap))
    let scale = header.nano ? 1_000_000_000.0 : 1_000_000.0
    return seconds + fraction / scale
}

private func addPacket(
    _ packet: [UInt8],
    time: TimeInterval,
    flows: inout [FlowKey: FlowBuild]
) throws {
    guard let version = packet.first else {
        return
    }
    if version >> 4 == 4 {
        try addIPv4(packet, time: time, flows: &flows)
        return
    }
    if version >> 4 == 6 {
        try addIPv6(packet, time: time, flows: &flows)
    }
}

private func addIPv4(
    _ packet: [UInt8],
    time: TimeInterval,
    flows: inout [FlowKey: FlowBuild]
) throws {
    let headerLength = Int(packet[0] & 0x0F) * 4
    if headerLength < 20 || packet.count < headerLength {
        throw CaptureParseError.truncated
    }
    if packet[9] != 6 {
        return
    }
    let total = Int(CaptureLink.u16(packet, 2))
    let end = total >= headerLength && total <= packet.count ? total : packet.count
    try addTCP(
        Array(packet[headerLength..<end]),
        source: Endpoint(address: CaptureLink.ipv4(packet, 12), port: 0),
        destination: Endpoint(address: CaptureLink.ipv4(packet, 16), port: 0),
        time: time,
        flows: &flows
    )
}

private func addIPv6(
    _ packet: [UInt8],
    time: TimeInterval,
    flows: inout [FlowKey: FlowBuild]
) throws {
    if packet.count < 40 {
        throw CaptureParseError.truncated
    }
    let next = packet[6]
    let payloadLength = Int(CaptureLink.u16(packet, 4))
    if next == 17 || next == 58 {
        return
    }
    if next != 6 {
        if payloadLength > 0 {
            throw CaptureParseError.unparsed
        }
        return
    }
    let end = min(packet.count, 40 + payloadLength)
    try addTCP(
        Array(packet[40..<end]),
        source: Endpoint(address: CaptureLink.ipv6(packet, 8), port: 0),
        destination: Endpoint(address: CaptureLink.ipv6(packet, 24), port: 0),
        time: time,
        flows: &flows
    )
}

private func addTCP(
    _ segment: [UInt8],
    source: Endpoint,
    destination: Endpoint,
    time: TimeInterval,
    flows: inout [FlowKey: FlowBuild]
) throws {
    if segment.count < 20 {
        throw CaptureParseError.truncated
    }
    let dataOffset = Int(segment[12] >> 4) * 4
    if dataOffset < 20 || segment.count < dataOffset {
        throw CaptureParseError.truncated
    }
    var from = source
    var to = destination
    from.port = CaptureLink.u16(segment, 0)
    to.port = CaptureLink.u16(segment, 2)
    let key = FlowKey(source: from, destination: to)
    var flow = flows[key] ?? FlowBuild()
    let sequence = CaptureLink.u32(segment, 4)
    if segment[13] & 0x02 != 0 {
        if flow.syn != sequence {
            flow.syn = sequence
            flow.segments.removeAll()
        }
    } else if dataOffset < segment.count {
        flow.segments.append(
            Segment(sequence: sequence, time: time, bytes: Array(segment[dataOffset...]))
        )
    }
    flows[key] = flow
}

private func assemble(
    _ segments: [Segment],
    syn: UInt32?
) throws -> (payload: [UInt8], times: [TimeInterval]) {
    let start: UInt32
    if let syn {
        start = syn &+ 1
    } else if let first = segments.map(\.sequence).min(by: sequenceBefore) {
        start = first
    } else {
        return ([], [])
    }
    var expected = start
    var payload: [UInt8] = []
    var times: [TimeInterval] = []
    for segment in segments.sorted(by: { sequenceBefore($0.sequence, $1.sequence) }) {
        let appended = try takeNew(segment, expected: &expected)
        payload.append(contentsOf: appended)
        for _ in appended {
            times.append(segment.time)
        }
    }
    return (payload, times)
}

private func takeNew(_ segment: Segment, expected: inout UInt32) throws -> [UInt8] {
    if segment.bytes.isEmpty {
        return []
    }
    let end = segment.sequence &+ UInt32(segment.bytes.count)
    if !sequenceBefore(expected, end) {
        return []
    }
    var skip = 0
    if sequenceBefore(segment.sequence, expected) {
        skip = Int(expected &- segment.sequence)
    } else if segment.sequence != expected {
        throw CaptureParseError.gap
    }
    expected = end
    if skip >= segment.bytes.count {
        return []
    }
    return Array(segment.bytes[skip...])
}

private func sequenceBefore(_ lhs: UInt32, _ rhs: UInt32) -> Bool {
    Int32(bitPattern: lhs &- rhs) < 0
}
