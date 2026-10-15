// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum SHA1Digest {
    static func hash(_ message: Data) -> Data {
        var hash0: UInt32 = 0x6745_2301
        var hash1: UInt32 = 0xEFCD_AB89
        var hash2: UInt32 = 0x98BA_DCFE
        var hash3: UInt32 = 0x1032_5476
        var hash4: UInt32 = 0xC3D2_E1F0
        let msg = padded(Array(message))
        var offset = 0
        while offset < msg.count {
            let words = schedule(msg, offset)
            var a = hash0
            var b = hash1
            var c = hash2
            var d = hash3
            var e = hash4
            for index in 0..<80 {
                let round = roundValue(index, b, c, d)
                let temp = rotl(a, 5) &+ round.f &+ e &+ round.k &+ words[index]
                e = d
                d = c
                c = rotl(b, 30)
                b = a
                a = temp
            }
            hash0 = hash0 &+ a
            hash1 = hash1 &+ b
            hash2 = hash2 &+ c
            hash3 = hash3 &+ d
            hash4 = hash4 &+ e
            offset += 64
        }
        var out = Data()
        for word in [hash0, hash1, hash2, hash3, hash4] {
            var big = word.bigEndian
            withUnsafeBytes(of: &big) { raw in
                out.append(contentsOf: raw)
            }
        }
        return out
    }

    private static func padded(_ message: [UInt8]) -> [UInt8] {
        var msg = message
        let bitCount = UInt64(message.count) &* 8
        msg.append(0x80)
        while msg.count % 64 != 56 {
            msg.append(0)
        }
        for shift in stride(from: 56, through: 0, by: -8) {
            msg.append(UInt8((bitCount >> UInt64(shift)) & 0xFF))
        }
        return msg
    }

    private static func schedule(_ msg: [UInt8], _ offset: Int) -> [UInt32] {
        var words = [UInt32](repeating: 0, count: 80)
        for index in 0..<16 {
            let start = offset + index * 4
            words[index] =
                (UInt32(msg[start]) << 24) | (UInt32(msg[start + 1]) << 16)
                | (UInt32(msg[start + 2]) << 8) | UInt32(msg[start + 3])
        }
        for index in 16..<80 {
            let mixed = words[index - 3] ^ words[index - 8] ^ words[index - 14] ^ words[index - 16]
            words[index] = rotl(mixed, 1)
        }
        return words
    }

    private static func roundValue(
        _ index: Int,
        _ b: UInt32,
        _ c: UInt32,
        _ d: UInt32
    ) -> (f: UInt32, k: UInt32) {
        switch index {
        case 0..<20:
            return ((b & c) | ((~b) & d), 0x5A82_7999)
        case 20..<40:
            return (b ^ c ^ d, 0x6ED9_EBA1)
        case 40..<60:
            return ((b & c) | (b & d) | (c & d), 0x8F1B_BCDC)
        default:
            return (b ^ c ^ d, 0xCA62_C1D6)
        }
    }

    private static func rotl(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value << count) | (value >> (32 - count))
    }
}

enum BEncodeWrite {
    static func string(_ value: String) -> Data {
        string(Data(value.utf8))
    }

    static func string(_ value: Data) -> Data {
        var data = Data("\(value.count):".utf8)
        data.append(value)
        return data
    }

    static func integer(_ value: Int) -> Data {
        Data("i\(value)e".utf8)
    }

    static func list(_ items: [Data]) -> Data {
        var data = Data("l".utf8)
        for item in items {
            data.append(item)
        }
        data.append(contentsOf: "e".utf8)
        return data
    }

    static func dictionary(_ pairs: [String: Data]) -> Data {
        var data = Data("d".utf8)
        for key in pairs.keys.sorted() {
            guard let value = pairs[key] else { continue }
            data.append(string(key))
            data.append(value)
        }
        data.append(contentsOf: "e".utf8)
        return data
    }
}

struct BuiltTorrent {
    var bytes: Data
    var infoHash: Data
    var payload: Data
    var pieces: [Data]
    var pieceLength: Int
}

enum TorrentBuild {
    struct FileSpec {
        var components: [String]
        var bytes: Data
    }

    static func single(
        name: String,
        payload: Data,
        pieceLength: Int,
        announce: String?,
        urlList: [String] = [],
        privateTorrent: Bool = true
    ) -> BuiltTorrent {
        build(
            Spec(
                name: name,
                files: nil,
                payload: payload,
                pieceLength: pieceLength,
                announce: announce,
                urlList: urlList,
                privateTorrent: privateTorrent
            )
        )
    }

    static func multiple(
        directory: String,
        files: [FileSpec],
        pieceLength: Int,
        announce: String
    ) -> BuiltTorrent {
        var payload = Data()
        for file in files {
            payload.append(file.bytes)
        }
        return build(
            Spec(
                name: directory,
                files: files,
                payload: payload,
                pieceLength: pieceLength,
                announce: announce,
                urlList: [],
                privateTorrent: true
            )
        )
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private struct Spec {
        var name: String
        var files: [FileSpec]?
        var payload: Data
        var pieceLength: Int
        var announce: String?
        var urlList: [String]
        var privateTorrent: Bool
    }

    private static func build(_ spec: Spec) -> BuiltTorrent {
        let slices = split(spec.payload, spec.pieceLength)
        var hashes = Data()
        for slice in slices {
            hashes.append(SHA1Digest.hash(slice))
        }
        var info: [String: Data] = [
            "name": BEncodeWrite.string(spec.name),
            "piece length": BEncodeWrite.integer(spec.pieceLength),
            "pieces": BEncodeWrite.string(hashes)
        ]
        if spec.privateTorrent {
            info["private"] = BEncodeWrite.integer(1)
        }
        if let files = spec.files {
            info["files"] = fileList(files)
        } else {
            info["length"] = BEncodeWrite.integer(spec.payload.count)
        }
        let infoBytes = BEncodeWrite.dictionary(info)
        var top: [String: Data] = ["info": infoBytes]
        if let announce = spec.announce {
            top["announce"] = BEncodeWrite.string(announce)
        }
        if let only = spec.urlList.first, spec.urlList.count == 1 {
            top["url-list"] = BEncodeWrite.string(only)
        } else if spec.urlList.count > 1 {
            top["url-list"] = BEncodeWrite.list(spec.urlList.map(BEncodeWrite.string))
        }
        return BuiltTorrent(
            bytes: BEncodeWrite.dictionary(top),
            infoHash: SHA1Digest.hash(infoBytes),
            payload: spec.payload,
            pieces: slices,
            pieceLength: spec.pieceLength
        )
    }

    private static func fileList(_ files: [FileSpec]) -> Data {
        var items: [Data] = []
        for file in files {
            let path = BEncodeWrite.list(file.components.map(BEncodeWrite.string))
            let entry = BEncodeWrite.dictionary([
                "length": BEncodeWrite.integer(file.bytes.count),
                "path": path
            ])
            items.append(entry)
        }
        return BEncodeWrite.list(items)
    }

    private static func split(_ payload: Data, _ pieceLength: Int) -> [Data] {
        if payload.isEmpty {
            return []
        }
        var slices: [Data] = []
        var offset = 0
        while offset < payload.count {
            let end = min(offset + pieceLength, payload.count)
            slices.append(payload.subdata(in: offset..<end))
            offset = end
        }
        return slices
    }
}
