import Darwin
import Foundation
import XCTest
@testable import NovaComputerUseCore

final class UnixSocketIPCTests: XCTestCase {
    func testConnectedSocketReportsPeerProcessIdentifier() async throws {
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ncu-peer-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let listener = try UnixSocketListener(socketURL: directory.appendingPathComponent("peer.sock"))
        let client = Task {
            try await UnixSocketIPC.connect(
                path: directory.appendingPathComponent("peer.sock").path,
                deadline: Date().addingTimeInterval(1)
            )
        }
        let serverConnection = try await listener.accept(deadline: Date().addingTimeInterval(1))
        let clientConnection = try await client.value
        defer {
            serverConnection.close()
            clientConnection.close()
        }

        XCTAssertEqual(try serverConnection.peerProcessIdentifier(), getpid())
        XCTAssertEqual(try clientConnection.peerProcessIdentifier(), getpid())
    }

    func testCodeSignatureVerifierRequiresTheExactExpectedSignedCode() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["5"]
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }
        let verifier = CodeSignaturePeerVerifier()

        XCTAssertTrue(verifier.isValidPeer(
            processIdentifier: process.processIdentifier,
            expectedCodeAt: URL(fileURLWithPath: "/bin/sleep")
        ))
        XCTAssertFalse(verifier.isValidPeer(
            processIdentifier: process.processIdentifier,
            expectedCodeAt: URL(fileURLWithPath: "/usr/bin/true")
        ))
    }
}
