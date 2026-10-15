// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

enum POSIX {
    private static var streamSocket: Int32 {
        #if os(Linux)
        Int32(SOCK_STREAM.rawValue)
        #else
        SOCK_STREAM
        #endif
    }

    static func errnoText() -> String {
        String(cString: strerror(errno))
    }

    static func randomBytes(count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }
        let fd = open("/dev/urandom", O_RDONLY)
        if fd < 0 {
            throw EngineError.settingsWriteFailed(errnoText())
        }
        defer { close(fd) }
        var bytes = [UInt8](repeating: 0, count: count)
        var got = 0
        while got < count {
            let n = bytes.withUnsafeMutableBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return read(fd, base.advanced(by: got), count - got)
            }
            if n < 0 {
                if errno == EINTR { continue }
                throw EngineError.settingsWriteFailed(errnoText())
            }
            if n == 0 {
                throw EngineError.settingsWriteFailed("urandom ended early")
            }
            got += n
        }
        return bytes
    }

    static func makePrivateDirectory() throws -> String {
        var base = FileManager.default.temporaryDirectory.path
        if !base.hasSuffix("/") {
            base += "/"
        }
        let template = base + "umb-aria2.XXXXXX"
        var bytes = Array(template.utf8) + [0]
        let pointer = bytes.withUnsafeMutableBytes { buffer -> UnsafeMutablePointer<CChar>? in
            guard let base = buffer.baseAddress else { return nil }
            return mkdtemp(base.assumingMemoryBound(to: CChar.self))
        }
        if pointer == nil {
            throw EngineError.temporaryDirectoryFailed(errnoText())
        }
        let path = bytes.withUnsafeBufferPointer { buffer -> String in
            buffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: buffer.count) {
                String(cString: $0)
            }
        }
        if chmod(path, mode_t(0o700)) != 0 {
            _ = unlink(path)
            throw EngineError.temporaryDirectoryFailed(errnoText())
        }
        return path
    }

    static func permissions(of path: String) throws -> Int {
        var info = stat()
        if lstat(path, &info) != 0 {
            throw EngineError.settingsPermissions(errnoText())
        }
        return Int(info.st_mode & 0o777)
    }

    static func isRegularFile(_ path: String) -> Bool {
        var info = stat()
        if lstat(path, &info) != 0 {
            return false
        }
        return (info.st_mode & S_IFMT) == S_IFREG
    }

    static func writeNewFile(path: String, contents: Data) throws {
        let fd = open(path, O_CREAT | O_WRONLY | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        if fd < 0 {
            throw EngineError.settingsWriteFailed(errnoText())
        }
        var openFD = fd
        defer {
            if openFD >= 0 {
                close(openFD)
            }
        }
        if fchmod(fd, mode_t(0o600)) != 0 {
            throw EngineError.settingsPermissions(errnoText())
        }
        try writeAll(fd: fd, data: contents)
        if fsync(fd) != 0 {
            throw EngineError.settingsWriteFailed(errnoText())
        }
        let mode = try permissions(of: path)
        if mode != 0o600 {
            throw EngineError.settingsPermissions(String(mode, radix: 8))
        }
        close(fd)
        openFD = -1
    }

    static func removeFile(_ path: String) throws {
        if unlink(path) != 0 {
            throw EngineError.settingsWriteFailed(errnoText())
        }
    }

    static func writeAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let n = write(fd, base.advanced(by: sent), raw.count - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw EngineError.settingsWriteFailed(errnoText())
                }
                sent += n
            }
        }
    }

    static func acceptClient(_ fd: Int32) -> Int32? {
        let client = accept(fd, nil, nil)
        if client < 0 {
            return nil
        }
        return client
    }

    static func closeFD(_ fd: Int32) {
        if fd >= 0 {
            close(fd)
        }
    }

    static func setSendTimeout(fd: Int32, seconds: Int) throws {
        var timeout = timeval()
        timeout.tv_sec = time_t(seconds)
        timeout.tv_usec = 0
        if setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) != 0 {
            throw EngineError.transport(errnoText())
        }
    }

    static func setReceiveTimeout(fd: Int32, seconds: Int) throws {
        var timeout = timeval()
        timeout.tv_sec = time_t(seconds)
        timeout.tv_usec = 0
        if setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) != 0 {
            throw EngineError.transport(errnoText())
        }
    }

    static func readOnce(fd: Int32, max: Int) throws -> Data? {
        var chunk = [UInt8](repeating: 0, count: max)
        let n = chunk.withUnsafeMutableBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return read(fd, base, max)
        }
        if n < 0 {
            if errno == EINTR {
                return try readOnce(fd: fd, max: max)
            }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                return nil
            }
            throw EngineError.transport(errnoText())
        }
        if n == 0 {
            return nil
        }
        return Data(chunk.prefix(n))
    }

    static func listenLoopback() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, streamSocket, 0)
        if fd < 0 {
            throw EngineError.transport(errnoText())
        }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                bind(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bound != 0 {
            close(fd)
            throw EngineError.transport(errnoText())
        }
        if listen(fd, 16) != 0 {
            close(fd)
            throw EngineError.transport(errnoText())
        }
        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                getsockname(fd, raw, &length)
            }
        }
        if named != 0 {
            close(fd)
            throw EngineError.transport(errnoText())
        }
        let port = UInt16(bigEndian: actual.sin_port)
        if port == 0 {
            close(fd)
            throw EngineError.transport("no port")
        }
        return (fd, port)
    }

    static func connectLoopback(port: UInt16, timeoutSeconds: Int) throws -> Int32 {
        let fd = socket(AF_INET, streamSocket, 0)
        if fd < 0 {
            throw EngineError.transport(errnoText())
        }
        #if os(macOS)
        var nosig: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
        #endif
        let flags = fcntl(fd, F_GETFL, 0)
        if flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0 {
            close(fd)
            throw EngineError.transport(errnoText())
        }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let started = withUnsafePointer(to: &address) { pointer -> Int32 in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { raw in
                connect(fd, raw, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if started != 0 && errno != EINPROGRESS {
            let text = errnoText()
            close(fd)
            throw EngineError.transport(text)
        }
        if started != 0 {
            var pollState = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let waited = poll(&pollState, 1, Int32(timeoutSeconds * 1000))
            if waited <= 0 {
                close(fd)
                throw EngineError.transport(waited == 0 ? "connect timeout" : errnoText())
            }
            var socketError: Int32 = 0
            var errorLength = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &errorLength) != 0 || socketError != 0 {
                if socketError != 0 {
                    errno = socketError
                }
                let text = errnoText()
                close(fd)
                throw EngineError.transport(text)
            }
        }
        if fcntl(fd, F_SETFL, flags) < 0 {
            close(fd)
            throw EngineError.transport(errnoText())
        }
        try setReceiveTimeout(fd: fd, seconds: timeoutSeconds)
        var sendTimeout = timeval()
        sendTimeout.tv_sec = time_t(timeoutSeconds)
        sendTimeout.tv_usec = 0
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    static func sendAll(fd: Int32, data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                #if os(Linux)
                let flags = Int32(MSG_NOSIGNAL)
                #else
                let flags: Int32 = 0
                #endif
                let n = send(fd, base.advanced(by: sent), raw.count - sent, flags)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw EngineError.transport(errnoText())
                }
                sent += n
            }
        }
    }

    static func freeLoopbackPort() throws -> UInt16 {
        let listened = try listenLoopback()
        close(listened.fd)
        return listened.port
    }
}
