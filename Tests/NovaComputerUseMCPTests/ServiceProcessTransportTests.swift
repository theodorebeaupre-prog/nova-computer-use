import Darwin
import Foundation
import XCTest
@testable import NovaComputerUseCore
@testable import NovaComputerUseMCP

final class ServiceProcessTransportTests: XCTestCase {
    func testBundledServiceURLUsesSelectableHelperApp() {
        let adapter = URL(fileURLWithPath: "/tmp/plugin/bin/NovaComputerUseMCP")

        XCTAssertEqual(
            siblingServiceURL(adapterURL: adapter).path,
            "/tmp/plugin/bin/NovaComputerUseService.app/Contents/MacOS/NovaComputerUseService"
        )
    }

    func testServiceApplicationURLUsesSiblingBundle() {
        let adapter = URL(fileURLWithPath: "/tmp/plugin/bin/NovaComputerUseMCP")

        XCTAssertEqual(
            siblingServiceApplicationURL(adapterURL: adapter).path,
            "/tmp/plugin/bin/NovaComputerUseService.app"
        )
    }

    func testApplicationTransportSendsTypedTextOnlyOverSocketAndLeavesNoRegularFiles() async throws {
        let fixture = try ApplicationTransportFixture()
        let typedText = "do-not-persist-this-secret"
        let received = ReceivedApplicationRequest()
        let launcher = CapturingApplicationLauncher { arguments in
            guard let socketPath = arguments.value(after: "--ipc-socket"),
                  let token = arguments.value(after: "--ipc-token") else {
                received.store(error: "Missing socket launch arguments")
                return
            }
            Task.detached {
                do {
                    let connection = try SocketTestClient.connect(path: socketPath)
                    try connection.write(Data(token.utf8))
                    let requestData = try connection.readFrame()
                    let request = try JSONDecoder().decode(ServiceRequest.self, from: requestData)
                    received.store(request: request)
                    let response = try JSONEncoder().encode(ServiceResponse.success(id: request.id, result: .null))
                    try connection.writeFrame(response)
                } catch {
                    received.store(error: String(describing: error))
                }
            }
        }
        let transport = try ServiceApplicationTransport(
            applicationURL: fixture.applicationURL,
            ipcRoot: fixture.ipcRoot,
            launcher: launcher
        )

        let result = try await transport.call(operation: .typeText, arguments: ["text": .string(typedText)])

        XCTAssertEqual(result, .null)
        XCTAssertNil(received.error)
        XCTAssertEqual(received.request?.operation, .typeText)
        XCTAssertEqual(received.request?.arguments["text"], .string(typedText))
        XCTAssertFalse(launcher.arguments.joined(separator: " ").contains(typedText))
        XCTAssertEqual(try fixture.regularFiles(), [])
    }

    func testApplicationTransportTimesOutAndRemovesItsSocketDirectory() async throws {
        let fixture = try ApplicationTransportFixture()
        let launcher = CapturingApplicationLauncher { _ in }
        let transport = try ServiceApplicationTransport(
            applicationURL: fixture.applicationURL,
            ipcRoot: fixture.ipcRoot,
            launcher: launcher,
            responseTimeout: 0.05
        )

        do {
            _ = try await transport.call(operation: .listApps, arguments: [:])
            XCTFail("Expected a bounded response timeout")
        } catch let error as ServiceError {
            XCTAssertEqual(error, ServiceError(
                code: .internalError,
                message: "NovaComputerUseService response timed out"
            ))
        }

        XCTAssertEqual(try fixture.regularFiles(), [])
        XCTAssertEqual(try fixture.childEntries(), [])
    }

    func testShutdownReturnsAfterGracefulChildExitWithoutSignals() async throws {
        let process = FakeServiceChildProcess(waitResults: [true])
        let fixtures = try TransportFixtures(process: process)

        await fixtures.transport.shutdown()

        XCTAssertEqual(process.startCount, 1)
        XCTAssertEqual(process.waitTimeouts, [0.01])
        XCTAssertEqual(process.terminateCount, 0)
        XCTAssertEqual(process.killCount, 0)
    }

    func testShutdownEscalatesFromEOFToSIGTERMToSIGKILLWithBoundedWaits() async throws {
        let process = FakeServiceChildProcess(waitResults: [false, false, true])
        let fixtures = try TransportFixtures(process: process)

        await fixtures.transport.shutdown()

        XCTAssertEqual(process.waitTimeouts, [0.01, 0.02, 0.03])
        XCTAssertEqual(process.terminateCount, 1)
        XCTAssertEqual(process.killCount, 1)
    }

    func testSIGTERMResistantRealChildIsKilledAndReapedWithoutOrphan() async throws {
        let transport = try ServiceProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            shutdownTimeouts: .init(graceful: 0.03, terminate: 0.03, kill: 0.2)
        )
        let pid = await transport.childProcessIdentifier
        try await Task.sleep(for: .milliseconds(30))

        await transport.shutdown()

        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testChildExitFailsCallWithInternalError() async throws {
        let transport = try ServiceProcessTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            shutdownTimeouts: .fastTests
        )
        try await Task.sleep(for: .milliseconds(20))

        await assertInternalError(from: transport)
        await transport.shutdown()
    }

    func testMalformedChildResponseFailsCallWithInternalError() async throws {
        let transport = try ServiceProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read line; printf 'not-json\\n'"],
            shutdownTimeouts: .fastTests
        )

        await assertInternalError(from: transport)
        await transport.shutdown()
    }

    func testMismatchedChildResponseFailsCallWithInternalError() async throws {
        let transport = try ServiceProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read line; printf '%s\\n' '{\"id\":\"wrong\",\"result\":null}'"],
            shutdownTimeouts: .fastTests
        )

        await assertInternalError(from: transport)
        await transport.shutdown()
    }

    func testClosedRequestPipeFailsWriteWithInternalError() async throws {
        let process = FakeServiceChildProcess(waitResults: [true])
        let fixtures = try TransportFixtures(process: process)
        try fixtures.requestInput.close()

        await assertInternalError(from: fixtures.transport)
        await fixtures.transport.shutdown()
    }

    func testSilentChildCallTimesOutAndCanBeReaped() async throws {
        let transport = try ServiceProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read line; sleep 30"],
            shutdownTimeouts: .fastTests,
            responseTimeout: 0.05
        )
        let pid = await transport.childProcessIdentifier
        let started = Date()

        do {
            _ = try await transport.call(operation: .listApps, arguments: [:])
            XCTFail("Expected response timeout")
        } catch let error as ServiceError {
            XCTAssertEqual(error, ServiceError(
                code: .internalError,
                message: "NovaComputerUseService response timed out"
            ))
        } catch {
            XCTFail("Expected ServiceError, got \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        await transport.shutdown()
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testShutdownInterruptsSilentCallAndLeavesNoChild() async throws {
        let transport = try ServiceProcessTransport(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "read line; sleep 30"],
            shutdownTimeouts: .fastTests,
            responseTimeout: 30
        )
        let pid = await transport.childProcessIdentifier
        let call = Task { () -> ServiceError? in
            do {
                _ = try await transport.call(operation: .listApps, arguments: [:])
                return nil
            } catch let error as ServiceError {
                return error
            } catch {
                return ServiceError(code: .internalError, message: "Unexpected error")
            }
        }
        try await Task.sleep(for: .milliseconds(30))

        await transport.shutdown()
        let callError = await call.value

        XCTAssertEqual(callError?.code, .internalError)
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testOversizedChildResponseFailsBeforeUnboundedAccumulation() async throws {
        let transport = try ServiceProcessTransport(
            executableURL: URL(fileURLWithPath: "/usr/bin/perl"),
            arguments: ["-e", "scalar <STDIN>; print \"x\" x (1024 * 1024 + 1); sleep 1"],
            shutdownTimeouts: .fastTests,
            responseTimeout: 2
        )

        do {
            _ = try await transport.call(operation: .listApps, arguments: [:])
            XCTFail("Expected oversized response failure")
        } catch let error as ServiceError {
            XCTAssertEqual(error, ServiceError(
                code: .internalError,
                message: "NovaComputerUseService response exceeds maximum size"
            ))
        } catch {
            XCTFail("Expected ServiceError, got \(error)")
        }
        await transport.shutdown()
    }

    private func assertInternalError(
        from transport: ServiceProcessTransport,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await transport.call(operation: .listApps, arguments: [:])
            XCTFail("Expected internal_error", file: file, line: line)
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, .internalError, file: file, line: line)
        } catch {
            XCTFail("Expected ServiceError, got \(error)", file: file, line: line)
        }
    }
}

private extension ChildShutdownTimeouts {
    static let fastTests = ChildShutdownTimeouts(graceful: 0.01, terminate: 0.01, kill: 0.1)
}

private final class TransportFixtures {
    let transport: ServiceProcessTransport
    let requestInput: FileHandle
    private let responseOutput: FileHandle
    private let requestPipe: Pipe
    private let responsePipe: Pipe

    init(process: FakeServiceChildProcess) throws {
        requestPipe = Pipe()
        responsePipe = Pipe()
        requestInput = requestPipe.fileHandleForWriting
        responseOutput = responsePipe.fileHandleForReading
        transport = try ServiceProcessTransport(
            process: process,
            requestInput: requestInput,
            responseOutput: responseOutput,
            shutdownTimeouts: .init(graceful: 0.01, terminate: 0.02, kill: 0.03)
        )
    }
}

private final class FakeServiceChildProcess: ServiceChildProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var remainingWaitResults: [Bool]
    private var running = true
    private(set) var startCount = 0
    private(set) var waitTimeouts: [TimeInterval] = []
    private(set) var terminateCount = 0
    private(set) var killCount = 0

    init(waitResults: [Bool]) {
        remainingWaitResults = waitResults
    }

    var isRunning: Bool {
        lock.withLock { running }
    }

    var processIdentifier: Int32 { 12345 }

    func start() throws {
        lock.withLock { startCount += 1 }
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        lock.withLock {
            waitTimeouts.append(timeout)
            let result = remainingWaitResults.isEmpty ? false : remainingWaitResults.removeFirst()
            if result { running = false }
            return result
        }
    }

    func terminate() {
        lock.withLock { terminateCount += 1 }
    }

    func kill() {
        lock.withLock { killCount += 1 }
    }
}

private final class ApplicationTransportFixture {
    let root: URL
    let ipcRoot: URL
    let applicationURL = URL(fileURLWithPath: "/Applications/NovaComputerUseService.app")

    init() throws {
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ncu-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
        ipcRoot = root.appendingPathComponent("ipc", isDirectory: true)
        try FileManager.default.createDirectory(at: ipcRoot, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func regularFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: ipcRoot,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        return try (enumerator?.allObjects as? [URL] ?? []).filter {
            try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
        }
    }

    func childEntries() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: ipcRoot,
            includingPropertiesForKeys: nil
        )
    }
}

private final class CapturingApplicationLauncher: ServiceApplicationLaunching, @unchecked Sendable {
    private let lock = NSLock()
    private let onLaunch: @Sendable ([String]) -> Void
    private var recordedArguments: [String] = []

    init(onLaunch: @escaping @Sendable ([String]) -> Void) {
        self.onLaunch = onLaunch
    }

    var arguments: [String] {
        lock.withLock { recordedArguments }
    }

    func launch(applicationURL: URL, arguments: [String]) throws -> any ServiceApplicationLaunch {
        lock.withLock { recordedArguments = arguments }
        onLaunch(arguments)
        return TestApplicationLaunch()
    }
}

private final class TestApplicationLaunch: ServiceApplicationLaunch, @unchecked Sendable {
    var isRunning: Bool { true }
    func terminate() {}
}

private final class ReceivedApplicationRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequest: ServiceRequest?
    private var storedError: String?

    var request: ServiceRequest? { lock.withLock { storedRequest } }
    var error: String? { lock.withLock { storedError } }

    func store(request: ServiceRequest) {
        lock.withLock { storedRequest = request }
    }

    func store(error: String) {
        lock.withLock { storedError = error }
    }
}

private final class SocketTestClient {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    deinit { close() }

    static func connect(path: String) throws -> SocketTestClient {
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            _ = Darwin.close(descriptor)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.initializeMemory(as: UInt8.self, repeating: 0)
            destination.copyBytes(from: pathBytes)
        }
        do {
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else { throw POSIXError(.ECONNREFUSED) }
        } catch {
            _ = Darwin.close(descriptor)
            throw error
        }
        return SocketTestClient(descriptor: descriptor)
    }

    func close() {
        _ = Darwin.close(descriptor)
    }

    func write(_ data: Data) throws {
        var written = 0
        try data.withUnsafeBytes { bytes in
            while written < bytes.count {
                let result = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                guard result > 0 else { throw POSIXError(.EPIPE) }
                written += result
            }
        }
    }

    func writeFrame(_ data: Data) throws {
        var length = UInt32(data.count).bigEndian
        try withUnsafeBytes(of: &length) { try write(Data($0)) }
        try write(data)
    }

    func readFrame() throws -> Data {
        let prefix = try readExactly(4)
        let length = prefix.withUnsafeBytes { $0.load(as: UInt32.self).bigEndian }
        guard length <= 1 * 1024 * 1024 else { throw POSIXError(.EMSGSIZE) }
        return try readExactly(Int(length))
    }

    private func readExactly(_ count: Int) throws -> Data {
        var data = Data()
        while data.count < count {
            var buffer = [UInt8](repeating: 0, count: count - data.count)
            let result = buffer.withUnsafeMutableBytes {
                Darwin.read(descriptor, $0.baseAddress, $0.count)
            }
            guard result > 0 else { throw POSIXError(.ECONNRESET) }
            data.append(contentsOf: buffer.prefix(result))
        }
        return data
    }
}

private extension Array where Element == String {
    func value(after flag: String) -> String? {
        guard let index = firstIndex(of: flag), indices.contains(index + 1) else { return nil }
        return self[index + 1]
    }
}
