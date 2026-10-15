// umbilical downloads files. It never seeds.
// Copyright (C) 2026 Karim Smires
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// SHA-256 as lowercase hex. License device ids use this so the raw
/// IOPlatformUUID never leaves the Mac.
enum SHA256Hex {
    static func digest(_ text: String) -> String {
        hex(hash(Array(text.utf8)))
    }

    private static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(_ message: [UInt8]) -> [UInt8] {
        var bytes = message
        let bitLength = UInt64(message.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 {
            bytes.append(0)
        }
        var shift = 56
        while shift >= 0 {
            bytes.append(UInt8((bitLength >> shift) & 0xff))
            shift -= 8
        }

        var state = initialState
        var offset = 0
        while offset < bytes.count {
            let end = offset + 64
            compress(Array(bytes[offset..<end]), into: &state)
            offset = end
        }
        return wordsToBytes(state)
    }

    private static func compress(_ block: [UInt8], into state: inout [UInt32]) {
        var words = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            let start = index * 4
            words[index] =
                (UInt32(block[start]) << 24)
                | (UInt32(block[start + 1]) << 16)
                | (UInt32(block[start + 2]) << 8)
                | UInt32(block[start + 3])
        }
        for index in 16..<64 {
            let first = smallSigma0(words[index - 15])
            let second = smallSigma1(words[index - 2])
            words[index] = words[index - 16] &+ first &+ words[index - 7] &+ second
        }
        mix(words, into: &state)
    }

    private static func mix(_ words: [UInt32], into state: inout [UInt32]) {
        var a = state[0]
        var b = state[1]
        var c = state[2]
        var d = state[3]
        var e = state[4]
        var f = state[5]
        var g = state[6]
        var h = state[7]
        for index in 0..<64 {
            let temp1 =
                h &+ bigSigma1(e) &+ choose(e, f, g) &+ roundConstants[index] &+ words[index]
            let temp2 = bigSigma0(a) &+ majority(a, b, c)
            h = g
            g = f
            f = e
            e = d &+ temp1
            d = c
            c = b
            b = a
            a = temp1 &+ temp2
        }
        state[0] = state[0] &+ a
        state[1] = state[1] &+ b
        state[2] = state[2] &+ c
        state[3] = state[3] &+ d
        state[4] = state[4] &+ e
        state[5] = state[5] &+ f
        state[6] = state[6] &+ g
        state[7] = state[7] &+ h
    }

    private static func rotr(_ value: UInt32, _ count: UInt32) -> UInt32 {
        (value >> count) | (value << (32 - count))
    }

    private static func bigSigma0(_ value: UInt32) -> UInt32 {
        rotr(value, 2) ^ rotr(value, 13) ^ rotr(value, 22)
    }

    private static func bigSigma1(_ value: UInt32) -> UInt32 {
        rotr(value, 6) ^ rotr(value, 11) ^ rotr(value, 25)
    }

    private static func smallSigma0(_ value: UInt32) -> UInt32 {
        rotr(value, 7) ^ rotr(value, 18) ^ (value >> 3)
    }

    private static func smallSigma1(_ value: UInt32) -> UInt32 {
        rotr(value, 17) ^ rotr(value, 19) ^ (value >> 10)
    }

    private static func choose(_ e: UInt32, _ f: UInt32, _ g: UInt32) -> UInt32 {
        (e & f) ^ (~e & g)
    }

    private static func majority(_ a: UInt32, _ b: UInt32, _ c: UInt32) -> UInt32 {
        (a & b) ^ (a & c) ^ (b & c)
    }

    private static func wordsToBytes(_ words: [UInt32]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(words.count * 4)
        for word in words {
            bytes.append(UInt8((word >> 24) & 0xff))
            bytes.append(UInt8((word >> 16) & 0xff))
            bytes.append(UInt8((word >> 8) & 0xff))
            bytes.append(UInt8(word & 0xff))
        }
        return bytes
    }

    private static let initialState: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
        0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19
    ]

    private static let roundConstants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5,
        0x3956_c25b, 0x59f1_11f1, 0x923f_82a4, 0xab1c_5ed5,
        0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3,
        0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7, 0xc19b_f174,
        0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc,
        0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da,
        0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967,
        0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13,
        0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85,
        0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3,
        0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070,
        0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5,
        0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208,
        0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7, 0xc671_78f2
    ]
}
