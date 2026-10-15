// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum CaptureLink {
    static func packet(_ frame: [UInt8], link: UInt32) throws -> [UInt8]? {
        switch link {
        // 0 is NULL, used by macOS lo0. 108 is LOOP. Both prefix a 4-byte family.
        case 0, 108:
            return ipFrame(Array(frame.dropFirst(4)))
        case 1:
            return try ethernet(frame)
        case 101:
            return ipFrame(frame)
        case 113:
            return try cooked(frame, header: 16, etherAt: 14)
        case 276:
            return try cooked(frame, header: 20, etherAt: 0)
        default:
            throw CaptureParseError.unsupportedLink(link)
        }
    }

    static func readU32(_ bytes: [UInt8], _ offset: Int, _ swap: Bool) -> UInt32 {
        if swap {
            return u32(bytes, offset)
        }
        return UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    static func u16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    static func u32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        (UInt32(bytes[offset]) << 24) | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8) | UInt32(bytes[offset + 3])
    }

    static func ipv4(_ bytes: [UInt8], _ offset: Int) -> String {
        let b0 = bytes[offset]
        let b1 = bytes[offset + 1]
        let b2 = bytes[offset + 2]
        let b3 = bytes[offset + 3]
        return "\(b0).\(b1).\(b2).\(b3)"
    }

    static func ipv6(_ bytes: [UInt8], _ offset: Int) -> String {
        var groups: [String] = []
        var index = 0
        while index < 16 {
            let value = u16(bytes, offset + index)
            groups.append(String(value, radix: 16))
            index += 2
        }
        return groups.joined(separator: ":")
    }

    private static func ethernet(_ frame: [UInt8]) throws -> [UInt8]? {
        if frame.count < 14 {
            throw CaptureParseError.truncated
        }
        var offset = 14
        var ether = u16(frame, 12)
        if ether == 0x8100 {
            if frame.count < 18 {
                throw CaptureParseError.truncated
            }
            offset = 18
            ether = u16(frame, 16)
        }
        return ipEther(ether, Array(frame.dropFirst(offset)))
    }

    private static func cooked(
        _ frame: [UInt8],
        header: Int,
        etherAt: Int
    ) throws -> [UInt8]? {
        if frame.count < header {
            throw CaptureParseError.truncated
        }
        return ipEther(u16(frame, etherAt), Array(frame.dropFirst(header)))
    }

    private static func ipFrame(_ frame: [UInt8]) -> [UInt8]? {
        guard let first = frame.first else {
            return nil
        }
        let version = first >> 4
        if version == 4 || version == 6 {
            return frame
        }
        return nil
    }

    private static func ipEther(_ ether: UInt16, _ payload: [UInt8]) -> [UInt8]? {
        if ether == 0x0800 || ether == 0x86DD {
            return payload
        }
        return nil
    }
}
