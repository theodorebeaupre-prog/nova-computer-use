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
            guard let socketPath = arguments.value(after: "--ipc-socket") else {
                received.store(error: "Missing socket launch arguments")
                return
            }
            Task.detached {
                do {
                    let connection = try SocketTestClient.connect(path: socketPath)
                    try connection.authenticateAsService()
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
            launcher: launcher,
            peerVerifier: AllowingTransportPeerVerifier()
        )

        let result = try await transport.call(operation: .typeText, arguments: ["text": .string(typedText)])

        XCTAssertEqual(result, .null)
        XCTAssertNil(received.error)
        XCTAssertEqual(received.request?.operation, .typeText)
        XCTAssertEqual(received.request?.arguments["text"], .string(typedText))
        XCTAssertFalse(launcher.arguments.joined(separator: " ").contains(typedText))
        XCTAssertEqual(try fixture.regularFiles(), [])
    }

    func testApplicationTransportKeepsOneHelperSessionForSnapshotThenElementClick() async throws {
        let fixture = try ApplicationTransportFixture()
        let launcher = CapturingApplicationLauncher { arguments in
            guard let socketPath = arguments.value(after: "--ipc-socket") else { return }
            Task.detached {
                guard let connection = try? SocketTestClient.connect(path: socketPath) else { return }
                defer { connection.close() }
                do {
                    try connection.authenticateAsService()
                    var hasSnapshot = false
                    while true {
                        let requestData = try connection.readFrame()
                        let request = try JSONDecoder().decode(ServiceRequest.self, from: requestData)
                        let response: ServiceResponse
                        switch request.operation {
                        case .getAppState:
                            hasSnapshot = true
                            response = .success(id: request.id, result: .object(["snapshot": .object([:])]))
                        case .click where hasSnapshot:
                            response = .success(id: request.id, result: .object(["ok": .bool(true)]))
                        case .click:
                            response = .failure(
                                id: request.id,
                                ServiceError(code: .staleSnapshot, message: "Snapshot expired")
                            )
                        default:
                            response = .success(id: request.id, result: .null)
                        }
                        try connection.writeFrame(JSONEncoder().encode(response))
                    }
                } catch {
                    // Closing the persistent socket ends the simulated helper session.
                }
            }
        }
        let transport = try ServiceApplicationTransport(
            applicationURL: fixture.applicationURL,
            ipcRoot: fixture.ipcRoot,
            launcher: launcher,
            peerVerifier: AllowingTransportPeerVerifier()
        )
        defer { Task { await transport.shutdown() } }

        _ = try await transport.call(operation: .getAppState, arguments: ["app": .string("Notes")])
        let click = try await transport.call(operation: .click, arguments: [
            "app": .string("Notes"),
            "element_index": .int(0)
        ])

        XCTAssertEqual(click, .object(["ok": .bool(true)]))
        XCTAssertEqual(launcher.launchCount, 1)
    }

    func testApplicationTransportKeepsCaptureUntilShutdown() async throws {
        let fixture = try ApplicationTransportFixture()
        let captureURL = fixture.root.appendingPathComponent("capture.png")
        let helperFinished = expectation(description: "persistent helper cleaned its capture")
        let launcher = CapturingApplicationLauncher { arguments in
            guard let socketPath = arguments.value(after: "--ipc-socket") else { return }
            Task.detached {
                guard let connection = try? SocketTestClient.connect(path: socketPath) else { return }
                defer {
                    connection.close()
                    try? FileManager.default.removeItem(at: captureURL)
                    helperFinished.fulfill()
                }
                do {
                    try connection.authenticateAsService()
                    while true {
                        let requestData = try connection.readFrame()
                        let request = try JSONDecoder().decode(ServiceRequest.self, from: requestData)
                        try Data("capture".utf8).write(to: captureURL)
                        let response = ServiceResponse.success(id: request.id, result: .object([
                            "capture": .object(["path": .string(captureURL.path)])
                        ]))
                        try connection.writeFrame(JSONEncoder().encode(response))
                    }
                } catch {
                    // Closing the persistent socket ends the simulated helper session.
                }
            }
        }
        let transport = try ServiceApplicationTransport(
            applicationURL: fixture.applicationURL,
            ipcRoot: fixture.ipcRoot,
            launcher: launcher,
            peerVerifier: AllowingTransportPeerVerifier()
        )

        _ = try await transport.call(operation: .getAppState, arguments: ["app": .string("Notes")])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(FileManager.default.fileExists(atPath: captureURL.path))

        await transport.shutdown()
        await fulfillment(of: [helperFinished], timeout: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: captureURL.path))
    }

    func testApplicationTransportDoesNotPutSessionSecretInLaunchArguments() async throws {
        let fixture = try ApplicationTransportFixture()
        let launcher = CapturingApplicationLauncher { arguments in
            guard let socketPath = arguments.value(after: "--ipc-socket") else { return }
            Task.detached {
                guard let connection = try? SocketTestClient.connect(path: socketPath) else { return }
                defer { connection.close() }
                do {
                    try connection.authenticateAsService()
                    let requestData = try connection.readFrame()
                    let request = try JSONDecoder().decode(ServiceRequest.self, from: requestData)
                    try connection.writeFrame(JSONEncoder().encode(
                        ServiceResponse.success(id: request.id, result: .null)
                    ))
                } catch {}
            }
        }
        let transport = try ServiceApplicationTransport(
            applicationURL: fixture.applicationURL,
            ipcRoot: fixture.ipcRoot,
            launcher: launcher,
            peerVerifier: AllowingTransportPeerVerifier()
        )

        _ = try await transport.call(operation: .listApps, arguments: [:])
        await transport.shutdown()

        XCTAssertFalse(launcher.arguments.contains("--ipc-token"))
    }

    func testApplicationTransportRejectsWrongHelperProofBeforeSendingRequest() async throws {
        let fixture = try ApplicationTransportFixture()
        let received = ReceivedApplicationRequest()
        let launcher = CapturingApplicationLauncher { arguments in
            guard let socketPath = arguments.value(after: "--ipc-socket") else { return }
            Task.detached {
                guard let connection = try? SocketTestClient.connect(path: socketPath) else { return }
                defer { connection.close() }
                do {
                    let challenge = Data(repeating: 0x8A, count: ServiceSocketSession.challengeByteCount)
                    try connection.writeFrame(challenge)
                    _ = try connection.readFrame()
                    try connection.writeFrame(Data(repeating: 0x17, count: ServiceSocketSession.challengeByteCount))
                    let requestData = try connection.readFrame()
                    received.store(request: try JSONDecoder().decode(ServiceRequest.self, from: requestData))
                } catch {}
            }
        }
        let transport = try ServiceApplicationTransport(
            applicationURL: fixture.applicationURL,
            ipcRoot: fixture.ipcRoot,
            launcher: launcher,
            peerVerifier: AllowingTransportPeerVerifier(),
            responseTimeout: 0.1
        )

        do {
            _ = try await transport.call(operation: .listApps, arguments: [:])
            XCTFail("Expected helper authentication failure")
        } catch let error as ServiceError {
            XCTAssertEqual(error.code, .internalError)
        }
        await transport.shutdown()

        XCTAssertNil(received.request)
    }

    func testApplicationTransportAndSocketSessionPreserveRealDispatcherStateAndCapture() async throws {
        let fixture = try ApplicationTransportFixture()
        let dispatcherFixture = PersistentDispatcherFixture(captureDirectory: fixture.root)
        let helperExit = DispatchSemaphore(value: 0)
        let applicationLaunch = WaitingApplicationLaunch(exitSignal: helperExit)
        let launcher = CapturingApplicationLauncher(applicationLaunch: applicationLaunch) { arguments in
            guard let socketPath = arguments.value(after: "--ipc-socket") else { return }
            Task.detached {
                defer { helperExit.signal() }
                try? await ServiceSocketSession.run(
                    socketPath: socketPath,
                    expectedPeerCodeURL: URL(fileURLWithPath: "/tmp/NovaComputerUseMCP"),
                    dispatcher: dispatcherFixture.dispatcher,
                    peerVerifier: AllowingTransportPeerVerifier(),
                    challengeGenerator: { Data(repeating: 0x3C, count: 32) },
                    connectionTimeout: 1,
                    authenticationTimeout: 1,
                    idleTimeout: 1
                )
            }
        }
        let transport = try ServiceApplicationTransport(
            applicationURL: fixture.applicationURL,
            ipcRoot: fixture.ipcRoot,
            launcher: launcher,
            peerVerifier: AllowingTransportPeerVerifier(),
            heartbeatInterval: 0.1
        )

        let state = try await transport.call(
            operation: .getAppState,
            arguments: ["app": .string("Notes")]
        )
        let capturePath = state.objectValue?["capture"]?.objectValue?["path"]?.stringValue
        XCTAssertNotNil(capturePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: capturePath!))
        try await Task.sleep(for: .milliseconds(1_250))

        let click = try await transport.call(operation: .click, arguments: [
            "app": .string("Notes"),
            "element_index": .int(0)
        ])
        XCTAssertEqual(click, .object(["ok": .bool(true)]))
        XCTAssertEqual(dispatcherFixture.input.clickCount, 1)
        XCTAssertEqual(launcher.launchCount, 1)

        await transport.shutdown()
        XCTAssertFalse(FileManager.default.fileExists(atPath: capturePath!))
        XCTAssertEqual(dispatcherFixture.capturer.cleanupCount, 1)
        XCTAssertEqual(applicationLaunch.waitTimeouts, [1])
    }

    func testApplicationTransportTimesOutAndRemovesItsSocketDirectory() async throws {
        let fixture = try ApplicationTransportFixture()
        let launcher = CapturingApplicationLauncher { _ in }
        let transport = try ServiceApplicationTransport(
            applicationURL: fixture.applicationURL,
            ipcRoot: fixture.ipcRoot,
            launcher: launcher,
            peerVerifier: AllowingTransportPeerVerifier(),
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
    private let applicationLaunch: any ServiceApplicationLaunch
    private var recordedArguments: [String] = []

    init(
        applicationLaunch: any ServiceApplicationLaunch = TestApplicationLaunch(),
        onLaunch: @escaping @Sendable ([String]) -> Void
    ) {
        self.applicationLaunch = applicationLaunch
        self.onLaunch = onLaunch
    }

    var arguments: [String] {
        lock.withLock { recordedArguments }
    }

    var launchCount: Int {
        lock.withLock { recordedLaunchCount }
    }

    private var recordedLaunchCount = 0

    func launch(applicationURL: URL, arguments: [String]) throws -> any ServiceApplicationLaunch {
        lock.withLock {
            recordedArguments = arguments
            recordedLaunchCount += 1
        }
        onLaunch(arguments)
        return applicationLaunch
    }
}

private final class TestApplicationLaunch: ServiceApplicationLaunch, @unchecked Sendable {
    var isRunning: Bool { true }
    func waitForExit(timeout: TimeInterval) -> Bool { true }
    func terminate() {}
    func kill() {}
}

private final class WaitingApplicationLaunch: ServiceApplicationLaunch, @unchecked Sendable {
    private let exitSignal: DispatchSemaphore
    private let lock = NSLock()
    private(set) var waitTimeouts: [TimeInterval] = []

    init(exitSignal: DispatchSemaphore) {
        self.exitSignal = exitSignal
    }

    var isRunning: Bool { true }

    func waitForExit(timeout: TimeInterval) -> Bool {
        lock.withLock { waitTimeouts.append(timeout) }
        return exitSignal.wait(timeout: .now() + timeout) == .success
    }

    func terminate() {}
    func kill() {}
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

private struct AllowingTransportPeerVerifier: PeerProcessIdentityVerifying {
    func isValidPeer(processIdentifier: pid_t, expectedCodeAt url: URL) -> Bool { true }
}

private final class PersistentDispatcherFixture: @unchecked Sendable {
    let inspector = PersistentInspector()
    let input = PersistentInput()
    let capturer: PersistentCapturer
    let dispatcher: ServiceDispatcher

    init(captureDirectory: URL) {
        capturer = PersistentCapturer(directory: captureDirectory)
        dispatcher = ServiceDispatcher(
            catalog: PersistentCatalog(),
            inspector: inspector,
            elementResolver: inspector,
            input: input,
            applicationActivator: PersistentActivator(),
            permissions: PersistentPermissions(),
            screenCapturer: capturer
        )
    }
}

private struct PersistentCatalog: ApplicationCataloging {
    func applications() -> [ApplicationDescriptor] { [.persistentFixture] }
    func resolve(_ query: String) throws -> ApplicationDescriptor { .persistentFixture }
}

private struct PersistentActivator: ApplicationActivating {
    func activateAndVerifyFrontmost(_ app: ApplicationDescriptor) -> Bool { true }
}

private struct PersistentPermissions: PermissionChecking {
    func hasAccessibilityPermission() -> Bool { true }
    func hasScreenRecordingPermission() -> Bool { true }
}

private final class PersistentInspector: AccessibilityInspecting, SnapshotElementReferenceResolving, @unchecked Sendable {
    private var hasSnapshot = false

    func snapshot(app: ApplicationDescriptor, maxDepth: Int, maxElements: Int) throws -> AccessibilitySnapshot {
        hasSnapshot = true
        return AccessibilitySnapshot(
            token: UUID(),
            app: app,
            text: "Save",
            elements: [.persistentFixture]
        )
    }

    func element(snapshotToken: UUID, index: Int) throws -> SnapshotElement { .persistentFixture }

    func resolveElementReference(snapshotToken: UUID, index: Int) throws -> SnapshotElementReference {
        try resolveLatestElementReference(app: .persistentFixture, index: index)
    }

    func resolveLatestElementReference(app: ApplicationDescriptor, index: Int) throws -> SnapshotElementReference {
        guard hasSnapshot else {
            throw ServiceError(code: .staleSnapshot, message: "Snapshot expired")
        }
        return SnapshotElementReference(axReference: AXElementReference(identifier: "persistent"))
    }

    func latestElement(app: ApplicationDescriptor, index: Int) throws -> SnapshotElement {
        guard hasSnapshot else {
            throw ServiceError(code: .staleSnapshot, message: "Snapshot expired")
        }
        return .persistentFixture
    }
}

private final class PersistentInput: InputControlling, @unchecked Sendable {
    private(set) var clickCount = 0
    func validate(coordinate: CGPoint) throws {}
    func click(element: SnapshotElementReference?, coordinate: CGPoint?, button: MouseButton, count: Int) throws {
        clickCount += 1
    }
    func typeText(_ text: String) throws {}
    func pressKey(_ key: String) throws {}
    func scroll(direction: ScrollDirection, pages: Int, anchor: CGPoint?) throws {}
}

private final class PersistentCapturer: ScreenCapturing, @unchecked Sendable {
    let path: URL
    private(set) var cleanupCount = 0

    init(directory: URL) {
        path = directory.appendingPathComponent("persistent-capture.png")
    }

    func captureMainDisplay() async throws -> CaptureResult {
        try Data("capture".utf8).write(to: path)
        return CaptureResult(path: path.path, displayID: 1, width: 1, height: 1)
    }

    func cleanup() {
        Thread.sleep(forTimeInterval: 0.1)
        cleanupCount += 1
        try? FileManager.default.removeItem(at: path)
    }
}

private extension ApplicationDescriptor {
    static let persistentFixture = ApplicationDescriptor(
        name: "Notes",
        bundleIdentifier: "com.apple.Notes",
        path: "/System/Applications/Notes.app",
        processIdentifier: 42
    )
}

private extension SnapshotElement {
    static let persistentFixture = SnapshotElement(
        index: 0,
        role: "AXButton",
        title: "Save",
        value: nil,
        frame: SnapshotFrame(x: 10, y: 10, width: 20, height: 20),
        actions: ["AXPress"]
    )
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
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

    func authenticateAsService() throws {
        let challenge = Data(repeating: 0xC7, count: ServiceSocketSession.challengeByteCount)
        try writeFrame(challenge)
        let response = try readFrame()
        guard response.count == ServiceSocketSession.challengeByteCount * 2,
              Data(response.prefix(ServiceSocketSession.challengeByteCount)) == challenge else {
            throw POSIXError(.EAUTH)
        }
        try writeFrame(Data(response.suffix(ServiceSocketSession.challengeByteCount)))
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
