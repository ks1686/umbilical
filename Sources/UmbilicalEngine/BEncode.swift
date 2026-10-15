// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum BEncoded {
    case integer(Int64)
    case data(Data)
    case list([BEncoded])
    case dictionary([(String, BEncoded)])

    var integer: Int64? {
        guard case .integer(let value) = self else { return nil }
        return value
    }

    var bytes: Data? {
        guard case .data(let value) = self else { return nil }
        return value
    }

    var utf8: String? {
        guard let bytes else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    var list: [BEncoded]? {
        guard case .list(let value) = self else { return nil }
        return value
    }

    func lookup(_ key: String) -> BEncoded? {
        guard case .dictionary(let pairs) = self else { return nil }
        return pairs.first { $0.0 == key }?.1
    }
}

struct BEncodeParser {
    private let bytes: [UInt8]
    private var index: Int
    private var depth: Int
    private var nodes: Int

    static func parse(_ data: Data) throws -> BEncoded {
        if data.count > 1_048_576 {
            throw EngineError.torrentRejected("size")
        }
        var parser = BEncodeParser(bytes: [UInt8](data), index: 0, depth: 0, nodes: 0)
        let value = try parser.parseValue()
        if parser.index != parser.bytes.count {
            throw EngineError.torrentRejected("trailing")
        }
        return value
    }

    private mutating func parseValue() throws -> BEncoded {
        nodes += 1
        if nodes > 100_000 || index >= bytes.count {
            throw EngineError.torrentRejected("bencode")
        }
        switch bytes[index] {
        case UInt8(ascii: "i"):
            return .integer(try parseInteger())
        case UInt8(ascii: "l"):
            return .list(try parseList())
        case UInt8(ascii: "d"):
            return .dictionary(try parseDictionary())
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return .data(try parseString())
        default:
            throw EngineError.torrentRejected("bencode")
        }
    }

    private mutating func parseList() throws -> [BEncoded] {
        try enter()
        defer { depth -= 1 }
        index += 1
        var items: [BEncoded] = []
        while true {
            if index >= bytes.count {
                throw EngineError.torrentRejected("list")
            }
            if bytes[index] == UInt8(ascii: "e") {
                index += 1
                return items
            }
            if items.count >= 10_000 {
                throw EngineError.torrentRejected("list")
            }
            items.append(try parseValue())
        }
    }

    private mutating func parseDictionary() throws -> [(String, BEncoded)] {
        try enter()
        defer { depth -= 1 }
        index += 1
        var pairs: [(String, BEncoded)] = []
        var previous: Data?
        while true {
            if index >= bytes.count {
                throw EngineError.torrentRejected("dictionary")
            }
            if bytes[index] == UInt8(ascii: "e") {
                index += 1
                return pairs
            }
            if pairs.count >= 10_000 {
                throw EngineError.torrentRejected("dictionary")
            }
            let keyData = try parseString()
            if let previous, !previous.lexicographicallyPrecedes(keyData) {
                throw EngineError.torrentRejected("dictionary")
            }
            previous = keyData
            guard let key = String(data: keyData, encoding: .utf8) else {
                throw EngineError.torrentRejected("dictionary")
            }
            pairs.append((key, try parseValue()))
        }
    }

    private mutating func enter() throws {
        depth += 1
        if depth > 32 {
            throw EngineError.torrentRejected("bencode")
        }
    }

    private mutating func parseInteger() throws -> Int64 {
        index += 1
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") {
            index += 1
        }
        let digits = index
        while index < bytes.count, isDigit(bytes[index]) {
            index += 1
        }
        if digits == index || index >= bytes.count || bytes[index] != UInt8(ascii: "e") {
            throw EngineError.torrentRejected("integer")
        }
        let token = Data(bytes[start..<index])
        index += 1
        try rejectBadInteger(token)
        guard let text = String(data: token, encoding: .ascii), let value = Int64(text) else {
            throw EngineError.torrentRejected("integer")
        }
        return value
    }

    private func rejectBadInteger(_ token: Data) throws {
        let zero = UInt8(ascii: "0")
        let dash = UInt8(ascii: "-")
        if token.first == dash {
            if token.count < 2 || token[token.index(after: token.startIndex)] == zero {
                throw EngineError.torrentRejected("integer")
            }
            return
        }
        if token.count > 1, token.first == zero {
            throw EngineError.torrentRejected("integer")
        }
    }

    private mutating func parseString() throws -> Data {
        let start = index
        while index < bytes.count, isDigit(bytes[index]) {
            index += 1
        }
        if start == index || index >= bytes.count || bytes[index] != UInt8(ascii: ":") {
            throw EngineError.torrentRejected("string")
        }
        let lengthBytes = bytes[start..<index]
        if lengthBytes.count > 1, lengthBytes.first == UInt8(ascii: "0") {
            throw EngineError.torrentRejected("string")
        }
        index += 1
        guard
            let length = Int(String(bytes: lengthBytes, encoding: .ascii) ?? ""),
            length >= 0,
            bytes.count - index >= length
        else {
            throw EngineError.torrentRejected("string")
        }
        let slice = Data(bytes[index..<(index + length)])
        index += length
        return slice
    }

    private func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}
