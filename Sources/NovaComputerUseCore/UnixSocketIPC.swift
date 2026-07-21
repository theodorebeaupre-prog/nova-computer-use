@preconcurrency import Foundation
import Darwin

public enum UnixSocketIPCError: Error, Sendable {
    case timedOut
    case invalidFrame
    case connectionFailed
}

public final class UnixSocketListener: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    public init(socketURL: URL) throws {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UnixSocketIPCError.connectionFailed }

        do {
            var address = try UnixSocketIPC.address(for: socketURL.path)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0,
                  Darwin.chmod(socketURL.path, 0o600) == 0,
                  Darwin.listen(descriptor, 1) == 0 else {
                throw UnixSocketIPCError.connectionFailed
            }
            self.descriptor = descriptor
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
    }

    deinit { close() }

    public func close() {
        let descriptor = lock.withLock { () -> Int32 in
            defer { self.descriptor = -1 }
            return self.descriptor
        }
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }

    public func accept(deadline: Date) async throws -> UnixSocketConnection {
        while true {
            let descriptor = lock.withLock { self.descriptor }
            guard descriptor >= 0 else { throw UnixSocketIPCError.connectionFailed }
            try await UnixSocketIPC.waitForRead(descriptor: descriptor, deadline: deadline)
            let connection = Darwin.accept(descriptor, nil, nil)
            if connection >= 0 {
                var peerUID: uid_t = 0
                var peerGID: gid_t = 0
                guard getpeereid(connection, &peerUID, &peerGID) == 0, peerUID == getuid() else {
                    _ = Darwin.close(connection)
                    throw UnixSocketIPCError.connectionFailed
                }
                return UnixSocketConnection(descriptor: connection)
            }
            if errno == EINTR { continue }
            throw UnixSocketIPCError.connectionFailed
        }
    }
}

public final class UnixSocketConnection: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32

    fileprivate init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { close() }

    public func close() {
        let descriptor = lock.withLock { () -> Int32 in
            defer { self.descriptor = -1 }
            return self.descriptor
        }
        if descriptor >= 0 { _ = Darwin.close(descriptor) }
    }

    public func write(_ data: Data, deadline: Date) async throws {
        var written = 0
        while written < data.count {
            let descriptor = lock.withLock { self.descriptor }
            guard descriptor >= 0 else { throw UnixSocketIPCError.connectionFailed }
            try await UnixSocketIPC.waitForWrite(descriptor: descriptor, deadline: deadline)
            let count = try data.withUnsafeBytes { bytes in
                let result = Darwin.write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: written),
                    bytes.count - written
                )
                guard result > 0 else { throw UnixSocketIPCError.connectionFailed }
                return result
            }
            written += count
        }
    }

    public func writeFrame(_ data: Data, deadline: Date) async throws {
        guard data.count <= UnixSocketIPC.maximumFrameSize else { throw UnixSocketIPCError.invalidFrame }
        var length = UInt32(data.count).bigEndian
        let prefix = withUnsafeBytes(of: &length) { Data($0) }
        try await write(prefix, deadline: deadline)
        try await write(data, deadline: deadline)
    }

    public func readExactly(_ count: Int, deadline: Date) async throws -> Data {
        var data = Data()
        while data.count < count {
            let descriptor = lock.withLock { self.descriptor }
            guard descriptor >= 0 else { throw UnixSocketIPCError.connectionFailed }
            try await UnixSocketIPC.waitForRead(descriptor: descriptor, deadline: deadline)
            var buffer = [UInt8](repeating: 0, count: count - data.count)
            let bytesRead = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            guard bytesRead > 0 else { throw UnixSocketIPCError.connectionFailed }
            data.append(contentsOf: buffer.prefix(bytesRead))
        }
        return data
    }

    public func readFrame(deadline: Date) async throws -> Data {
        let prefix = try await readExactly(MemoryLayout<UInt32>.size, deadline: deadline)
        let length = prefix.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).bigEndian }
        guard length <= UnixSocketIPC.maximumFrameSize else { throw UnixSocketIPCError.invalidFrame }
        return try await readExactly(Int(length), deadline: deadline)
    }
}

public enum UnixSocketIPC {
    public static let maximumFrameSize = 1 * 1024 * 1024
    private static let pollMilliseconds: Int32 = 50

    public static func connect(path: String, deadline: Date) async throws -> UnixSocketConnection {
        while true {
            let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw UnixSocketIPCError.connectionFailed }
            let address: sockaddr_un
            do {
                address = try self.address(for: path)
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
            var mutableAddress = address
            let result = withUnsafePointer(to: &mutableAddress) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result == 0 {
                return UnixSocketConnection(descriptor: descriptor)
            }
            let connectionError = errno
            _ = Darwin.close(descriptor)
            guard connectionError == ENOENT || connectionError == ECONNREFUSED,
                  deadline.timeIntervalSinceNow > 0 else {
                throw UnixSocketIPCError.connectionFailed
            }
            try await Task.sleep(for: .milliseconds(pollMilliseconds))
        }
    }

    fileprivate static func address(for path: String) throws -> sockaddr_un {
        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw UnixSocketIPCError.connectionFailed
        }
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes)
        }
        return address
    }

    fileprivate static func waitForRead(descriptor: Int32, deadline: Date) async throws {
        try await wait(descriptor: descriptor, events: Int16(POLLIN), deadline: deadline)
    }

    fileprivate static func waitForWrite(descriptor: Int32, deadline: Date) async throws {
        try await wait(descriptor: descriptor, events: Int16(POLLOUT), deadline: deadline)
    }

    private static func wait(descriptor: Int32, events: Int16, deadline: Date) async throws {
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw UnixSocketIPCError.timedOut }
            let milliseconds = Int32(max(1, min(Double(pollMilliseconds), remaining * 1_000)))
            var pollDescriptor = pollfd(fd: descriptor, events: events, revents: 0)
            let result = Darwin.poll(&pollDescriptor, 1, milliseconds)
            if result > 0 { return }
            if result < 0, errno != EINTR { throw UnixSocketIPCError.connectionFailed }
            await Task.yield()
        }
    }
}
