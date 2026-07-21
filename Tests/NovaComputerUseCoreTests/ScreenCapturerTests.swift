import CoreGraphics
import Foundation
import XCTest
@testable import NovaComputerUseCore

final class ScreenCapturerTests: XCTestCase {
    func testPackageDeclaresMacOS15Floor() throws {
        let package = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Package.swift")

        XCTAssertTrue(try String(contentsOf: package, encoding: .utf8).contains("platforms: [.macOS(.v15)]"))
    }

    func testCaptureWritesOnePNGToTheServiceTemporaryDirectory() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaComputerUseTests-\(UUID().uuidString)", isDirectory: true)
        let backend = FakeScreenCaptureBackend(image: try makeImage())
        let capturer = ScreenCapturer(
            backend: backend,
            temporaryDirectory: directory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let result = try await capturer.captureMainDisplay()

        XCTAssertEqual(result.displayID, 42)
        XCTAssertEqual(result.width, 1)
        XCTAssertEqual(result.height, 1)
        XCTAssertTrue(result.path.hasPrefix(directory.path + "/"))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: result.path)).prefix(8), Data([137, 80, 78, 71, 13, 10, 26, 10]))
        XCTAssertEqual(backend.captureCount, 1)
    }

    func testCleanupDeletesAllCreatedCapturesAndIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaComputerUseTests-\(UUID().uuidString)", isDirectory: true)
        let capturer = ScreenCapturer(
            backend: FakeScreenCaptureBackend(image: try makeImage()),
            temporaryDirectory: directory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try await capturer.captureMainDisplay()
        let second = try await capturer.captureMainDisplay()
        capturer.cleanup()
        capturer.cleanup()

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: second.path))
    }

    func testNewCaptureDeletesPriorTrackedCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaComputerUseTests-\(UUID().uuidString)", isDirectory: true)
        let capturer = ScreenCapturer(
            backend: FakeScreenCaptureBackend(image: try makeImage()),
            temporaryDirectory: directory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try await capturer.captureMainDisplay()
        let second = try await capturer.captureMainDisplay()

        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
    }

    func testBackendFailurePreservesPreviousCapture() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaComputerUseTests-\(UUID().uuidString)", isDirectory: true)
        let capturer = ScreenCapturer(
            backend: FailingAfterFirstScreenCaptureBackend(image: try makeImage()),
            temporaryDirectory: directory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try await capturer.captureMainDisplay()
        do {
            _ = try await capturer.captureMainDisplay()
            XCTFail("Expected backend capture failure")
        } catch ScreenCaptureFixtureError.backendFailure {}

        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: first.path)).prefix(8),
            Data([137, 80, 78, 71, 13, 10, 26, 10])
        )

        capturer.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testPNGFinalizationFailurePreservesPreviousCaptureAndDeletesCandidate() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaComputerUseTests-\(UUID().uuidString)", isDirectory: true)
        let writer = FailingAfterWritingSecondPNGWriter()
        let capturer = ScreenCapturer(
            backend: FakeScreenCaptureBackend(image: try makeImage()),
            pngWriter: writer,
            temporaryDirectory: directory
        )
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = try await capturer.captureMainDisplay()
        do {
            _ = try await capturer.captureMainDisplay()
            XCTFail("Expected PNG finalization failure")
        } catch ScreenCaptureFixtureError.pngFinalizationFailure {}

        XCTAssertEqual(writer.attemptedURLs.count, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: first.path)), Data("complete".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.attemptedURLs[1].path))

        capturer.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
    }

    func testMainDisplaySelectionRejectsUnavailableMainDisplay() {
        XCTAssertThrowsError(try ScreenCaptureDisplaySelection.mainDisplayIndex(in: [2, 3], mainDisplayID: 1)) {
            XCTAssertEqual($0 as? ServiceError, ServiceError(code: .captureFailed, message: "Main display is unavailable"))
        }
    }

    func testInitializationSweepsStaleCapturePNGs() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovaComputerUseTests-\(UUID().uuidString)", isDirectory: true)
        let captureDirectory = directory.appendingPathComponent("NovaComputerUse", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)
        let stalePNG = captureDirectory.appendingPathComponent("orphan.png")
        let unrelated = captureDirectory.appendingPathComponent("keep.txt")
        try Data("stale".utf8).write(to: stalePNG)
        try Data("keep".utf8).write(to: unrelated)
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = ScreenCapturer(
            backend: FakeScreenCaptureBackend(image: try makeImage()),
            temporaryDirectory: directory
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: stalePNG.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }
}

private final class FakeScreenCaptureBackend: ScreenCaptureBacking {
    private let image: CGImage
    private(set) var captureCount = 0

    init(image: CGImage) {
        self.image = image
    }

    func captureMainDisplay() async throws -> CapturedScreenImage {
        captureCount += 1
        return CapturedScreenImage(displayID: 42, image: image)
    }
}

private final class FailingAfterFirstScreenCaptureBackend: ScreenCaptureBacking {
    private let image: CGImage
    private var captureCount = 0

    init(image: CGImage) {
        self.image = image
    }

    func captureMainDisplay() async throws -> CapturedScreenImage {
        captureCount += 1
        guard captureCount == 1 else { throw ScreenCaptureFixtureError.backendFailure }
        return CapturedScreenImage(displayID: 42, image: image)
    }
}

private final class FailingAfterWritingSecondPNGWriter: ScreenCapturePNGWriting {
    private(set) var attemptedURLs: [URL] = []

    func writePNG(_ image: CGImage, to url: URL) throws {
        attemptedURLs.append(url)
        try Data(attemptedURLs.count == 1 ? "complete".utf8 : "partial".utf8).write(to: url)
        if attemptedURLs.count == 2 {
            throw ScreenCaptureFixtureError.pngFinalizationFailure
        }
    }
}

private enum ScreenCaptureFixtureError: Error {
    case backendFailure
    case pngFinalizationFailure
}

private func makeImage() throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil,
        width: 1,
        height: 1,
        bitsPerComponent: 8,
        bytesPerRow: 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw XCTSkip("Unable to make a fixture image")
    }
    context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
    guard let image = context.makeImage() else { throw XCTSkip("Unable to make a fixture image") }
    return image
}
