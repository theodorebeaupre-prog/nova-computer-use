import CoreGraphics
import Darwin
import Dispatch
import Foundation
import XCTest
@testable import NovaComputerUseCore
@testable import NovaComputerUseService

final class ServiceLoopTests: XCTestCase {
    func testProcessesCompleteLineBeforeInputEOF() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("output.ndjson")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let input = Pipe()
        let fixtures = LoopFixtures()

        let task = Task {
            await ServiceLoop.run(
                input: input.fileHandleForReading,
                output: output,
                dispatcher: fixtures.dispatcher
            )
        }
        try input.fileHandleForWriting.write(contentsOf: Data(
            "{\"id\":\"live\",\"operation\":\"list_apps\",\"arguments\":{}}\n".utf8
        ))

        var respondedBeforeEOF = false
        for _ in 0..<20 {
            if !(try Data(contentsOf: outputURL)).isEmpty {
                respondedBeforeEOF = true
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        try input.fileHandleForWriting.close()
        await task.value
        try output.close()
        XCTAssertTrue(respondedBeforeEOF, "The persistent service must answer without waiting for stdin EOF")
    }

    func testContinuesAfterMalformedLine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input.ndjson")
        let outputURL = directory.appendingPathComponent("output.ndjson")
        let input = Data("""
        {\"id\":\"first\",\"operation\":\"list_apps\",\"arguments\":{}}
        not-json
        {\"id\":\"second\",\"operation\":\"list_apps\",\"arguments\":{}}
        """.utf8)
        try input.write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let inputHandle = try FileHandle(forReadingFrom: inputURL)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        await ServiceLoop.run(input: inputHandle, output: outputHandle, dispatcher: ServiceDispatcher())
        try inputHandle.close()
        try outputHandle.close()

        let responses = try String(contentsOf: outputURL, encoding: .utf8)
            .split(separator: "\n")
            .map { try JSONDecoder().decode(ServiceResponse.self, from: Data($0.utf8)) }

        XCTAssertEqual(responses.count, 3)
        XCTAssertEqual(responses[0].id, "first")
        XCTAssertEqual(responses[1], .failure(id: "", ServiceError(code: .invalidRequest, message: "Invalid request")))
        XCTAssertEqual(responses[2].id, "second")
    }

    func testDiscardsPartialLineWhenInputClosesWithAnError() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("output.ndjson")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(contentsOf: Data("not-json".utf8))

        let task = Task {
            await ServiceLoop.run(
                input: pipe.fileHandleForReading,
                output: output,
                dispatcher: ServiceDispatcher()
            )
        }
        try await Task.sleep(for: .milliseconds(100))
        try pipe.fileHandleForReading.close()
        await task.value
        try output.close()

        XCTAssertEqual(try Data(contentsOf: outputURL), Data())
    }

    func testCancellationClosesIdleInputAndCleansUpOnce() async throws {
        let pipe = Pipe()
        let output = FileHandle.standardOutput
        let fixtures = LoopFixtures()
        let finished = expectation(description: "service loop exits after cancellation")
        defer { try? pipe.fileHandleForReading.close() }

        let task = Task {
            await ServiceLoop.run(
                input: pipe.fileHandleForReading,
                output: output,
                dispatcher: fixtures.dispatcher
            )
            finished.fulfill()
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()

        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(fixtures.capturer.cleanupCount, 1)
    }

    func testWriteFailureStopsBeforeLaterRequestDispatch() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let inputURL = directory.appendingPathComponent("input.ndjson")
        let outputURL = directory.appendingPathComponent("output.ndjson")
        try Data("""
        {"id":"first","operation":"list_apps","arguments":{}}
        {"id":"second","operation":"list_apps","arguments":{}}
        """.utf8).write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)

        let input = try FileHandle(forReadingFrom: inputURL)
        let closedOutput = try FileHandle(forWritingTo: outputURL)
        try closedOutput.close()
        let fixtures = LoopFixtures()

        await ServiceLoop.run(input: input, output: closedOutput, dispatcher: fixtures.dispatcher)
        try input.close()

        XCTAssertEqual(fixtures.catalog.applicationsCount, 1)
        XCTAssertEqual(fixtures.capturer.cleanupCount, 1)
    }

    func testCancellationRacingEOFDiscardsBufferedValidLine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let outputURL = directory.appendingPathComponent("output.ndjson")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let output = try FileHandle(forWritingTo: outputURL)
        let request = "{\"id\":\"partial\",\"operation\":\"list_apps\",\"arguments\":{}}"
        let input = EOFBarrierInput(line: Data(request.utf8))
        let fixtures = LoopFixtures()
        let finished = expectation(description: "service loop exits after EOF cancellation race")
        defer {
            input.close()
            try? output.close()
        }

        let task = Task {
            await ServiceLoop.run(
                input: input,
                output: output,
                dispatcher: fixtures.dispatcher
            )
            finished.fulfill()
        }
        XCTAssertEqual(input.eofReadStarted.wait(timeout: .now() + 1), .success)
        task.cancel()
        input.releaseEOF()

        await fulfillment(of: [finished], timeout: 1)
        XCTAssertEqual(fixtures.catalog.applicationsCount, 0)
        XCTAssertEqual(fixtures.capturer.cleanupCount, 1)
    }

    func testOversizedServiceResponseIsReplacedWithBoundedErrorLine() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let inputURL = directory.appendingPathComponent("input.ndjson")
        let outputURL = directory.appendingPathComponent("output.ndjson")
        try Data("{\"id\":\"large\",\"operation\":\"list_apps\",\"arguments\":{}}\n".utf8)
            .write(to: inputURL)
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let input = try FileHandle(forReadingFrom: inputURL)
        let output = try FileHandle(forWritingTo: outputURL)
        let hugeName = String(repeating: "x", count: 2_048)
        let applications = (0..<1_000).map { index in
            ApplicationDescriptor(
                name: "\(index)-\(hugeName)",
                bundleIdentifier: "com.example.\(index)",
                path: "/Applications/\(index).app",
                processIdentifier: Int32(index)
            )
        }

        await ServiceLoop.run(
            input: input,
            output: output,
            dispatcher: LoopFixtures(applications: applications).dispatcher
        )
        try input.close()
        try output.close()

        let line = try Data(contentsOf: outputURL)
        XCTAssertLessThanOrEqual(line.count, 1 * 1_024 * 1_024)
        let response = try JSONDecoder().decode(ServiceResponse.self, from: line.dropLast())
        XCTAssertEqual(response, .failure(
            id: "large",
            ServiceError(code: .internalError, message: "Response exceeds maximum size")
        ))
    }

    func testServiceRejectsUnauthenticatedDirectStdioMode() async throws {
        let serviceURL = try builtServiceURL()
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        process.executableURL = serviceURL
        process.standardInput = input
        process.standardOutput = output
        process.standardError = output
        let terminated = expectation(description: "service rejects unauthenticated stdio")
        process.terminationHandler = { _ in terminated.fulfill() }
        try process.run()

        await fulfillment(of: [terminated], timeout: 1)

        XCTAssertEqual(process.terminationReason, .exit)
        XCTAssertNotEqual(process.terminationStatus, 0)
        try? input.fileHandleForWriting.close()
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        try? output.fileHandleForReading.close()
    }

    func testSocketSessionRejectsWrongChallengeResponseBeforeDispatch() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ncu-auth-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("session.sock")
        let listener = try UnixSocketListener(socketURL: socketURL)
        let fixtures = LoopFixtures()
        let expectedChallenge = Data(repeating: 0xA5, count: 32)
        let session = Task {
            try await ServiceSocketSession.run(
                socketPath: socketURL.path,
                expectedPeerCodeURL: URL(fileURLWithPath: "/tmp/NovaComputerUseMCP"),
                dispatcher: fixtures.dispatcher,
                peerVerifier: AllowingPeerVerifier(),
                challengeGenerator: { expectedChallenge },
                connectionTimeout: 1,
                authenticationTimeout: 1,
                idleTimeout: 1
            )
        }
        let connection = try await listener.accept(deadline: Date().addingTimeInterval(1))
        let challenge = try await connection.readFrame(deadline: Date().addingTimeInterval(1))
        XCTAssertEqual(challenge, expectedChallenge)
        try await connection.writeFrame(Data(repeating: 0x5A, count: 32), deadline: Date().addingTimeInterval(1))

        do {
            try await session.value
            XCTFail("Expected authentication failure")
        } catch let error as ServiceSocketSessionError {
            XCTAssertEqual(error, .authenticationFailed)
        }

        XCTAssertEqual(fixtures.catalog.applicationsCount, 0)
        XCTAssertEqual(fixtures.capturer.cleanupCount, 1)
    }

    func testSocketSessionRejectsUntrustedPeerBeforeDispatch() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ncu-identity-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("session.sock")
        let listener = try UnixSocketListener(socketURL: socketURL)
        let fixtures = LoopFixtures()
        let session = Task {
            try await ServiceSocketSession.run(
                socketPath: socketURL.path,
                expectedPeerCodeURL: URL(fileURLWithPath: "/tmp/NovaComputerUseMCP"),
                dispatcher: fixtures.dispatcher,
                peerVerifier: DenyingPeerVerifier(),
                challengeGenerator: { Data(repeating: 0x2E, count: 32) },
                connectionTimeout: 1,
                authenticationTimeout: 0.05,
                idleTimeout: 1
            )
        }
        let connection = try await listener.accept(deadline: Date().addingTimeInterval(1))
        defer { connection.close() }

        do {
            try await session.value
            XCTFail("Expected peer identity rejection")
        } catch let error as ServiceSocketSessionError {
            XCTAssertEqual(error, .peerIdentityRejected)
        }

        XCTAssertEqual(fixtures.catalog.applicationsCount, 0)
        XCTAssertEqual(fixtures.capturer.cleanupCount, 1)
    }

    func testSocketSessionIdleTimeoutCleansUpOnce() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ncu-idle-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socketURL = directory.appendingPathComponent("session.sock")
        let listener = try UnixSocketListener(socketURL: socketURL)
        let fixtures = LoopFixtures()
        let session = Task {
            try await ServiceSocketSession.run(
                socketPath: socketURL.path,
                expectedPeerCodeURL: URL(fileURLWithPath: "/tmp/NovaComputerUseMCP"),
                dispatcher: fixtures.dispatcher,
                peerVerifier: AllowingPeerVerifier(),
                challengeGenerator: { Data(repeating: 0x1D, count: 32) },
                connectionTimeout: 1,
                authenticationTimeout: 1,
                idleTimeout: 0.05
            )
        }
        let connection = try await listener.accept(deadline: Date().addingTimeInterval(1))
        let challenge = try await connection.readFrame(deadline: Date().addingTimeInterval(1))
        let peerChallenge = Data(repeating: 0xC7, count: ServiceSocketSession.challengeByteCount)
        var authenticationResponse = challenge
        authenticationResponse.append(peerChallenge)
        try await connection.writeFrame(authenticationResponse, deadline: Date().addingTimeInterval(1))
        let peerProof = try await connection.readFrame(deadline: Date().addingTimeInterval(1))
        XCTAssertEqual(peerProof, peerChallenge)

        try await session.value

        XCTAssertEqual(fixtures.capturer.cleanupCount, 1)
    }
}

private func builtServiceURL() throws -> URL {
    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let candidates = [
        packageRoot.appendingPathComponent(".build/debug/NovaComputerUseService"),
        packageRoot.appendingPathComponent(".build/x86_64-apple-macosx/debug/NovaComputerUseService"),
        packageRoot.appendingPathComponent(".build/arm64-apple-macosx/debug/NovaComputerUseService")
    ]
    guard let executable = candidates.first(where: {
        FileManager.default.isExecutableFile(atPath: $0.path)
    }) else {
        throw XCTSkip("NovaComputerUseService test product is unavailable")
    }
    return executable
}

private final class EOFBarrierInput: ServiceInputReading, @unchecked Sendable {
    let eofReadStarted = DispatchSemaphore(value: 0)
    private let line: Data
    private var didReturnLine = false
    private let lock = NSLock()
    private let eofGate = DispatchSemaphore(value: 0)

    init(line: Data) {
        self.line = line
    }

    func read(upToCount count: Int) throws -> Data? {
        lock.lock()
        if !didReturnLine {
            didReturnLine = true
            lock.unlock()
            return line
        }
        lock.unlock()

        eofReadStarted.signal()
        eofGate.wait()
        return Data()
    }

    func close() {}

    func releaseEOF() {
        eofGate.signal()
    }
}

private final class LoopFixtures: @unchecked Sendable {
    let catalog: LoopCatalog
    let capturer = CleanupCountingCapturer()
    let dispatcher: ServiceDispatcher

    init(applications: [ApplicationDescriptor] = []) {
        catalog = LoopCatalog(applications: applications)
        let inspector = LoopInspector()
        dispatcher = ServiceDispatcher(
            catalog: catalog,
            inspector: inspector,
            elementResolver: inspector,
            input: LoopInput(),
            applicationActivator: LoopApplicationActivator(),
            permissions: LoopPermissions(),
            screenCapturer: capturer
        )
    }
}

private struct LoopApplicationActivator: ApplicationActivating {
    func activateAndVerifyFrontmost(_ app: ApplicationDescriptor) -> Bool { true }
}

private final class LoopCatalog: ApplicationCataloging, @unchecked Sendable {
    private let values: [ApplicationDescriptor]
    private(set) var applicationsCount = 0

    init(applications: [ApplicationDescriptor]) {
        values = applications
    }

    func applications() -> [ApplicationDescriptor] {
        applicationsCount += 1
        return values
    }

    func resolve(_ query: String) throws -> ApplicationDescriptor {
        throw ServiceError(code: .applicationNotFound, message: "Application not found")
    }
}

private struct LoopInspector: AccessibilityInspecting, SnapshotElementReferenceResolving {
    func snapshot(app: ApplicationDescriptor, maxDepth: Int, maxElements: Int) throws -> AccessibilitySnapshot {
        throw ServiceError(code: .elementNotFound, message: "Element not found")
    }

    func element(snapshotToken: UUID, index: Int) throws -> SnapshotElement {
        throw ServiceError(code: .elementNotFound, message: "Element not found")
    }

    func resolveElementReference(snapshotToken: UUID, index: Int) throws -> SnapshotElementReference {
        throw ServiceError(code: .elementNotFound, message: "Element not found")
    }

    func resolveLatestElementReference(app: ApplicationDescriptor, index: Int) throws -> SnapshotElementReference {
        throw ServiceError(code: .elementNotFound, message: "Element not found")
    }

    func latestElement(app: ApplicationDescriptor, index: Int) throws -> SnapshotElement {
        throw ServiceError(code: .elementNotFound, message: "Element not found")
    }
}

private struct LoopInput: InputControlling {
    func validate(coordinate: CGPoint) throws {}
    func click(element: SnapshotElementReference?, coordinate: CGPoint?, button: MouseButton, count: Int) throws {}
    func typeText(_ text: String) throws {}
    func pressKey(_ key: String) throws {}
    func scroll(direction: ScrollDirection, pages: Int, anchor: CGPoint?) throws {}
}

private struct LoopPermissions: PermissionChecking {
    func hasAccessibilityPermission() -> Bool { true }
    func hasScreenRecordingPermission() -> Bool { true }
}

private final class CleanupCountingCapturer: ScreenCapturing, @unchecked Sendable {
    private(set) var cleanupCount = 0

    func captureMainDisplay() async throws -> CaptureResult {
        throw ServiceError(code: .captureFailed, message: "Unable to capture the display")
    }

    func cleanup() {
        cleanupCount += 1
    }
}

private struct AllowingPeerVerifier: PeerProcessIdentityVerifying {
    func isValidPeer(processIdentifier: pid_t, expectedCodeAt url: URL) -> Bool { true }
}

private struct DenyingPeerVerifier: PeerProcessIdentityVerifying {
    func isValidPeer(processIdentifier: pid_t, expectedCodeAt url: URL) -> Bool { false }
}
