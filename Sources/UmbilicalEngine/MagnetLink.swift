// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

enum MagnetLink {
    static func canonical(_ url: URL) throws -> String {
        guard url.scheme?.lowercased() == "magnet" else {
            throw EngineError.magnetRejected("scheme")
        }
        if url.user != nil || url.password != nil {
            throw EngineError.magnetRejected("scheme")
        }
        let raw = url.absoluteString
        if raw.count > 4096 || raw.contains("\n") || raw.contains("\r") || raw.contains("\0") {
            throw EngineError.magnetRejected("length")
        }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw EngineError.magnetRejected("scheme")
        }
        if let host = components.host, !host.isEmpty {
            throw EngineError.magnetRejected("scheme")
        }
        if !components.path.isEmpty || components.fragment != nil {
            throw EngineError.magnetRejected("scheme")
        }
        guard let items = components.queryItems, !items.isEmpty else {
            throw EngineError.magnetRejected("xt")
        }
        return try canonical(from: items)
    }

    private static func canonical(from items: [URLQueryItem]) throws -> String {
        var btih: String?
        var btmh: [String] = []
        var display: String?
        var trackers: [String] = []
        var webSeeds: [String] = []
        var exact: [String] = []
        var sources: [String] = []
        var peers: [String] = []
        var keyword: String?
        for item in items {
            guard let value = item.value, !value.isEmpty, value.count <= 2048 else {
                throw EngineError.magnetRejected("parameter")
            }
            if value.contains("\n") || value.contains("\r") || value.contains("\0") {
                throw EngineError.magnetRejected("parameter")
            }
            switch item.name.lowercased() {
            case "xt":
                try consumeExactTopic(value, btih: &btih, btmh: &btmh)
            case "dn":
                if display != nil {
                    throw EngineError.magnetRejected("dn")
                }
                display = try displayName(value)
            case "tr":
                try validateLocation(value, schemes: ["http", "https", "udp"], kind: "tracker")
                trackers.append(value)
            case "ws":
                try validateLocation(value, schemes: ["http", "https"], kind: "web-seed")
                webSeeds.append(value)
            case "xs":
                try validateLocation(value, schemes: ["http", "https"], kind: "web-seed")
                exact.append(value)
            case "as":
                try validateLocation(value, schemes: ["http", "https"], kind: "web-seed")
                sources.append(value)
            case "x.pe":
                try validatePeer(value)
                peers.append(value)
            case "kt":
                if keyword != nil {
                    throw EngineError.magnetRejected("parameter")
                }
                keyword = try keywordValue(value)
            default:
                throw EngineError.magnetRejected("parameter")
            }
        }
        guard let btih else {
            throw EngineError.magnetRejected("xt")
        }
        return try assemble(
            btih: btih,
            btmh: btmh,
            display: display,
            trackers: trackers,
            webSeeds: webSeeds,
            exact: exact,
            sources: sources,
            peers: peers,
            keyword: keyword
        )
    }

    private static func consumeExactTopic(
        _ value: String,
        btih: inout String?,
        btmh: inout [String]
    ) throws {
        let lower = value.lowercased()
        if lower.hasPrefix("urn:btih:") {
            let hex = try infoHashHex(String(lower.dropFirst("urn:btih:".count)))
            if let btih, btih != hex {
                throw EngineError.magnetRejected("xt")
            }
            btih = hex
            return
        }
        let prefix = "urn:btmh:1220"
        if lower.hasPrefix(prefix) {
            let digest = String(lower.dropFirst(prefix.count))
            guard digest.count == 64, digest.allSatisfy(\.isHexDigit) else {
                throw EngineError.magnetRejected("xt")
            }
            let canonical = prefix + digest
            if !btmh.contains(canonical) {
                btmh.append(canonical)
            }
            return
        }
        throw EngineError.magnetRejected("xt")
    }

    private static func infoHashHex(_ hash: String) throws -> String {
        if hash.count == 40, hash.allSatisfy(\.isHexDigit) {
            return hash.lowercased()
        }
        if hash.count == 32 {
            return try decodeBase32(hash).map { String(format: "%02x", $0) }.joined()
        }
        throw EngineError.magnetRejected("xt")
    }

    private static func decodeBase32(_ text: String) throws -> [UInt8] {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var output: [UInt8] = []
        var buffer = 0
        var bits = 0
        for character in text.uppercased() {
            guard let found = alphabet.firstIndex(of: character) else {
                throw EngineError.magnetRejected("xt")
            }
            let value = alphabet.distance(from: alphabet.startIndex, to: found)
            buffer = (buffer << 5) | value
            bits += 5
            if bits >= 8 {
                bits -= 8
                output.append(UInt8((buffer >> bits) & 0xFF))
                buffer &= (1 << bits) - 1
            }
        }
        if text.count != 32 || bits != 0 || output.count != 20 {
            throw EngineError.magnetRejected("xt")
        }
        return output
    }

    private static func displayName(_ value: String) throws -> String {
        do {
            try DownloadPath.validateOutputName(value)
        } catch {
            throw EngineError.magnetRejected("dn")
        }
        if hasControls(value) {
            throw EngineError.magnetRejected("dn")
        }
        return value
    }

    private static func keywordValue(_ value: String) throws -> String {
        if value.count > 200 || hasControls(value) || value.contains("/") || value.contains("\\") {
            throw EngineError.magnetRejected("parameter")
        }
        return value
    }

    private static func validatePeer(_ value: String) throws {
        let host: String
        let portText: String
        if value.hasPrefix("[") {
            guard
                let end = value.firstIndex(of: "]"),
                value[value.index(after: end)...].hasPrefix(":")
            else {
                throw EngineError.magnetRejected("peer")
            }
            host = String(value[value.index(after: value.startIndex)..<end])
            portText = String(value[value.index(end, offsetBy: 2)...])
        } else {
            guard let colon = value.lastIndex(of: ":") else {
                throw EngineError.magnetRejected("peer")
            }
            host = String(value[..<colon])
            portText = String(value[value.index(after: colon)...])
            if host.contains(":") || host.contains("/") {
                throw EngineError.magnetRejected("peer")
            }
        }
        guard !host.isEmpty, let port = Int(portText), (1...65535).contains(port) else {
            throw EngineError.magnetRejected("peer")
        }
    }

    private static func validateLocation(
        _ text: String,
        schemes: Set<String>,
        kind: String
    ) throws {
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased() else {
            throw EngineError.magnetRejected(kind)
        }
        if !schemes.contains(scheme) || url.user != nil || url.password != nil {
            throw EngineError.magnetRejected(kind)
        }
        if url.host?.isEmpty != false {
            throw EngineError.magnetRejected(kind)
        }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.contains("..") || parts.contains(".") {
            throw EngineError.magnetRejected(kind)
        }
    }

    private static func assemble(
        btih: String,
        btmh: [String],
        display: String?,
        trackers: [String],
        webSeeds: [String],
        exact: [String],
        sources: [String],
        peers: [String],
        keyword: String?
    ) throws -> String {
        var parts = ["xt=urn:btih:\(btih)"]
        for hash in btmh {
            parts.append("xt=\(try queryEncode(hash))")
        }
        if let display {
            parts.append("dn=\(try queryEncode(display))")
        }
        for tracker in trackers {
            parts.append("tr=\(try queryEncode(tracker))")
        }
        for seed in webSeeds {
            parts.append("ws=\(try queryEncode(seed))")
        }
        for source in exact {
            parts.append("xs=\(try queryEncode(source))")
        }
        for source in sources {
            parts.append("as=\(try queryEncode(source))")
        }
        for peer in peers {
            parts.append("x.pe=\(try queryEncode(peer))")
        }
        if let keyword {
            parts.append("kt=\(try queryEncode(keyword))")
        }
        let magnet = "magnet:?" + parts.joined(separator: "&")
        if magnet.count > 4096 {
            throw EngineError.magnetRejected("length")
        }
        return magnet
    }

    private static func queryEncode(_ value: String) throws -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        guard
            let encoded = value.addingPercentEncoding(withAllowedCharacters: allowed),
            !encoded.isEmpty
        else {
            throw EngineError.magnetRejected("parameter")
        }
        return encoded
    }

    private static func hasControls(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
    }
}
