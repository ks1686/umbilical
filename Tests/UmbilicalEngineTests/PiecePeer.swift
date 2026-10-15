// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@testable import UmbilicalEngine

final class PiecePeer {
    enum Role {
        case seeder
        case leecher
    }

    let port: UInt16
    let role: Role
    let infoHash: Data
    let peerID: Data
    let pieces: [Data]
    let holdIndex: Int?
    private let listenFD: Int32
    private let lock = NSLock()
    private let stopped = DispatchSemaphore(value: 0)
    private var running = true
    private var released = false
    private var handlers = 0
    private var handshakeCount = 0
    private var receivedBytes = 0

    init(
        role: Role,
        infoHash: Data,
        peerID: Data,
        pieces: [Data],
        holdIndex: Int?
    ) throws {
        if infoHash.count != 20 || peerID.count != 20 || pieces.isEmpty {
            throw FixtureError.badFixture
        }
        self.role = role
        self.infoHash = infoHash
        self.peerID = peerID
        self.pieces = pieces
        self.holdIndex = holdIndex
        let listened = try POSIX.listenLoopback()
        self.listenFD = listened.fd
        self.port = listened.port
    }

    func start() {
        Thread.detachNewThread { [self] in
            self.acceptLoop()
            self.stopped.signal()
        }
    }

    func releaseHold() {
        lock.lock()
        released = true
        lock.unlock()
    }

    func shouldContinue() -> Bool {
        lock.lock()
        let value = running
        lock.unlock()
        return value
    }

    func shouldRelease() -> Bool {
        lock.lock()
        let value = released || holdIndex == nil
        lock.unlock()
        return value
    }

    func noteHandshake() {
        lock.lock()
        handshakeCount += 1
        lock.unlock()
    }

    func notePieceBytes(_ count: Int) {
        lock.lock()
        receivedBytes += count
        lock.unlock()
    }

    var handshakes: Int {
        lock.lock()
        let value = handshakeCount
        lock.unlock()
        return value
    }

    var receivedPieceBytes: Int {
        lock.lock()
        let value = receivedBytes
        lock.unlock()
        return value
    }

    func stop() {
        lock.lock()
        running = false
        released = true
        lock.unlock()
        if let wake = try? POSIX.connectLoopback(port: port, timeoutSeconds: 1) {
            POSIX.closeFD(wake)
        }
        POSIX.closeFD(listenFD)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            lock.lock()
            let pending = handlers
            lock.unlock()
            if pending == 0 {
                break
            }
            usleep(50_000)
        }
        _ = stopped.wait(timeout: .now() + 2)
    }

    private func acceptLoop() {
        while shouldContinue() {
            guard let client = POSIX.acceptClient(listenFD) else {
                break
            }
            if !beginHandler() {
                POSIX.closeFD(client)
                break
            }
            Thread.detachNewThread { [self] in
                runPeerConnection(fd: client, peer: self)
                POSIX.closeFD(client)
                self.endHandler()
            }
        }
    }

    private func beginHandler() -> Bool {
        lock.lock()
        let keep = running
        if keep {
            handlers += 1
        }
        lock.unlock()
        return keep
    }

    private func endHandler() {
        lock.lock()
        handlers -= 1
        lock.unlock()
    }
}
