// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@testable import UmbilicalEngine

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

private enum PeerChunk {
    case data(Data)
    case eof
    case timeout
    case failed
}

private struct BlockRequest {
    var index: Int
    var begin: Int
    var length: Int
}

private enum HandshakeRead {
    case waiting
    case rejected
    case ready
}

private struct PeerSession {
    var buffer: [UInt8] = []
    var ready = false
    var pending: [BlockRequest] = []
    var asked = Date.distantPast

    mutating func pump(fd: Int32, peer: PiecePeer) -> Bool {
        if !ready {
            switch acceptHandshake(peer: peer) {
            case .waiting:
                return true
            case .rejected:
                return false
            case .ready:
                ready = true
                peer.noteHandshake()
                if !sendGreeting(fd: fd, peer: peer) {
                    return false
                }
            }
        }
        if !flushHold(fd: fd, peer: peer) || !refreshRequests(fd: fd, peer: peer) {
            return false
        }
        return drain(fd: fd, peer: peer)
    }

    mutating func onTimeout(fd: Int32, peer: PiecePeer) -> Bool {
        if !ready {
            return true
        }
        if !flushHold(fd: fd, peer: peer) || !refreshRequests(fd: fd, peer: peer) {
            return false
        }
        return true
    }

    private mutating func acceptHandshake(peer: PiecePeer) -> HandshakeRead {
        if buffer.count >= 20 && buffer[0] != 19 {
            return .rejected
        }
        if buffer.count < 68 {
            return .waiting
        }
        let name = Data(buffer[1..<20])
        let hash = Data(buffer[28..<48])
        if name != Data("BitTorrent protocol".utf8) || hash != peer.infoHash {
            return .rejected
        }
        buffer.removeFirst(68)
        return .ready
    }

    private mutating func sendGreeting(fd: Int32, peer: PiecePeer) -> Bool {
        var data = BTWire.handshake(infoHash: peer.infoHash, peerID: peer.peerID)
        let full = peer.role == .seeder
        data.append(BTWire.bitfield(pieceCount: peer.pieces.count, full: full))
        data.append(BTWire.unchoke())
        if peer.role == .leecher {
            data.append(BTWire.interested())
            data.append(BTWire.requests(for: peer.pieces))
            asked = Date()
        }
        return sendPeer(fd, data)
    }

    private mutating func refreshRequests(fd: Int32, peer: PiecePeer) -> Bool {
        guard peer.role == .leecher, Date().timeIntervalSince(asked) >= 0.05 else {
            return true
        }
        asked = Date()
        return sendPeer(fd, BTWire.requests(for: peer.pieces))
    }

    private mutating func flushHold(fd: Int32, peer: PiecePeer) -> Bool {
        guard peer.shouldRelease(), !pending.isEmpty else {
            return true
        }
        let queued = pending
        pending.removeAll()
        for request in queued {
            guard let block = blockBytes(peer: peer, request: request) else {
                continue
            }
            let message = BTWire.piece(
                index: request.index,
                begin: request.begin,
                block: block
            )
            if !sendPeer(fd, message) {
                return false
            }
        }
        return true
    }

    private mutating func drain(fd: Int32, peer: PiecePeer) -> Bool {
        while buffer.count >= 4 {
            let length = Int(readU32(buffer, 0))
            if length == 0 {
                buffer.removeFirst(4)
                continue
            }
            if length > 256 * 1024 || length < 1 {
                return false
            }
            let total = 4 + length
            if buffer.count < total {
                return true
            }
            let id = buffer[4]
            let payload = Array(buffer[5..<total])
            buffer.removeFirst(total)
            if !handle(id: id, payload: payload, fd: fd, peer: peer) {
                return false
            }
        }
        return true
    }

    private mutating func handle(
        id: UInt8,
        payload: [UInt8],
        fd: Int32,
        peer: PiecePeer
    ) -> Bool {
        if id == 7 && payload.count >= 8 {
            peer.notePieceBytes(payload.count - 8)
        }
        guard id == 6, payload.count >= 12, peer.role == .seeder else {
            return true
        }
        let request = BlockRequest(
            index: Int(readU32(payload, 0)),
            begin: Int(readU32(payload, 4)),
            length: Int(readU32(payload, 8))
        )
        if request.index == peer.holdIndex && !peer.shouldRelease() {
            if pending.count < 64 {
                pending.append(request)
            }
            return true
        }
        guard let block = blockBytes(peer: peer, request: request) else {
            return true
        }
        return sendPeer(
            fd,
            BTWire.piece(index: request.index, begin: request.begin, block: block)
        )
    }
}

func runPeerConnection(fd: Int32, peer: PiecePeer) {
    POSIX.ignorePipe(fd)
    setNoDelay(fd)
    setShortRead(fd)
    _ = try? POSIX.setSendTimeout(fd: fd, seconds: 5)
    var session = PeerSession()
    while peer.shouldContinue() {
        switch readPeerChunk(fd) {
        case .data(let chunk):
            session.buffer.append(contentsOf: chunk)
            if !session.pump(fd: fd, peer: peer) {
                return
            }
        case .eof, .failed:
            return
        case .timeout:
            if !session.onTimeout(fd: fd, peer: peer) {
                return
            }
        }
    }
}

private func blockBytes(peer: PiecePeer, request: BlockRequest) -> Data? {
    guard peer.pieces.indices.contains(request.index) else {
        return nil
    }
    let piece = peer.pieces[request.index]
    let end = request.begin + request.length
    guard request.begin >= 0, request.length > 0, end <= piece.count else {
        return nil
    }
    return piece.subdata(in: request.begin..<end)
}

private func sendPeer(_ fd: Int32, _ data: Data) -> Bool {
    (try? POSIX.sendAll(fd: fd, data: data)) != nil
}

private func readPeerChunk(_ fd: Int32) -> PeerChunk {
    let capacity = 16 * 1024
    var chunk = [UInt8](repeating: 0, count: capacity)
    while true {
        let count = chunk.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else {
                return -1
            }
            return read(fd, base, capacity)
        }
        if count > 0 {
            return .data(Data(chunk.prefix(count)))
        }
        if count == 0 {
            return .eof
        }
        if errno == EINTR {
            continue
        }
        if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
            return .timeout
        }
        return .failed
    }
}

private func setNoDelay(_ fd: Int32) {
    var enabled: Int32 = 1
    _ = setsockopt(
        fd,
        Int32(IPPROTO_TCP),
        TCP_NODELAY,
        &enabled,
        socklen_t(MemoryLayout<Int32>.size)
    )
}

private func setShortRead(_ fd: Int32) {
    var timeout = timeval()
    timeout.tv_sec = 0
    timeout.tv_usec = 200_000
    _ = setsockopt(
        fd,
        SOL_SOCKET,
        SO_RCVTIMEO,
        &timeout,
        socklen_t(MemoryLayout<timeval>.size)
    )
}
