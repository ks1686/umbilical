// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum BTWire {
    static let seederID = Data("-UM1000-SEEDER000001".utf8)
    static let leecherID = Data("-UM1000-LEECHER00001".utf8)

    static func handshake(infoHash: Data, peerID: Data) -> Data {
        var data = Data([19])
        data.append(contentsOf: "BitTorrent protocol".utf8)
        var reserved = [UInt8](repeating: 0, count: 8)
        reserved[7] = 0x04
        data.append(contentsOf: reserved)
        data.append(infoHash)
        data.append(peerID)
        return data
    }

    static func message(id: UInt8, payload: Data) -> Data {
        var data = Data()
        appendU32(UInt32(1 + payload.count), to: &data)
        data.append(id)
        data.append(payload)
        return data
    }

    static func bitfield(pieceCount: Int, full: Bool) -> Data {
        let width = max(1, (pieceCount + 7) / 8)
        var payload = Data(repeating: full ? 0xFF : 0, count: width)
        if full {
            let spare = width * 8 - pieceCount
            if spare > 0 {
                payload[width - 1] = 0xFF << spare
            }
        }
        return message(id: 5, payload: payload)
    }

    static func request(index: Int, begin: Int, length: Int) -> Data {
        var payload = Data()
        appendU32(UInt32(index), to: &payload)
        appendU32(UInt32(begin), to: &payload)
        appendU32(UInt32(length), to: &payload)
        return message(id: 6, payload: payload)
    }

    static func piece(index: Int, begin: Int, block: Data) -> Data {
        var payload = Data()
        appendU32(UInt32(index), to: &payload)
        appendU32(UInt32(begin), to: &payload)
        payload.append(block)
        return message(id: 7, payload: payload)
    }

    static func unchoke() -> Data {
        message(id: 1, payload: Data())
    }

    static func interested() -> Data {
        message(id: 2, payload: Data())
    }

    static func requests(for pieces: [Data]) -> Data {
        var data = Data()
        for (index, piece) in pieces.enumerated() {
            data.append(request(index: index, begin: 0, length: piece.count))
        }
        return data
    }

    private static func appendU32(_ value: UInt32, to data: inout Data) {
        var big = value.bigEndian
        withUnsafeBytes(of: &big) { raw in
            data.append(contentsOf: raw)
        }
    }
}

func readU32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
    let b0 = UInt32(bytes[offset])
    let b1 = UInt32(bytes[offset + 1])
    let b2 = UInt32(bytes[offset + 2])
    let b3 = UInt32(bytes[offset + 3])
    return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}
