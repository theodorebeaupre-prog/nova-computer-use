import Foundation
import XCTest
@testable import NovaInstallerCore

final class NovaInstallerCoreTests: XCTestCase {
    func testInspectorRecognizesCompleteInstallation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let codex = root.appendingPathComponent(".codex", isDirectory: true)
        let plugin = codex.appendingPathComponent("plugins/cache/nova/computer-use/1.0.0", isDirectory: true)
        try FileManager.default.createDirectory(at: plugin.appendingPathComponent("bin", isDirectory: true), withIntermediateDirectories: true)
        try Data().write(to: plugin.appendingPathComponent("bin/NovaComputerUseMCP"))
        try "[plugins.\"computer-use@nova\"]\nenabled = true\n".write(
            to: codex.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8
        )

        let report = NovaInspector.inspect(
            homeDirectory: root,
            executableSearchPaths: ["/bin/sh"],
            operatingSystem: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0),
            architecture: "x86_64"
        )

        XCTAssertTrue(report.macOSSupported)
        XCTAssertTrue(report.architectureSupported)
        XCTAssertTrue(report.codexAvailable)
        XCTAssertTrue(report.pluginInstalled)
        XCTAssertTrue(report.pluginEnabled)
    }

    func testInspectorRejectsUnsupportedSystems() {
        let report = NovaInspector.inspect(
            homeDirectory: URL(fileURLWithPath: "/nonexistent"),
            executableSearchPaths: [],
            operatingSystem: OperatingSystemVersion(majorVersion: 14, minorVersion: 7, patchVersion: 0),
            architecture: "ppc"
        )
        XCTAssertFalse(report.macOSSupported)
        XCTAssertFalse(report.architectureSupported)
        XCTAssertFalse(report.readyForInstallation)
    }

    func testInstallerUsesBoundedCommands() async throws {
        let runner = RecordingRunner()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("scripts/install-local.sh"))
        try Data().write(to: root.appendingPathComponent("scripts/uninstall-local.sh"))
        let resources = NovaResources(root: root)
        let installer = NovaInstaller(resources: resources, runner: runner)

        try await installer.install()
        try await installer.uninstall()
        let commands = await runner.commands

        XCTAssertEqual(commands.count, 2)
        XCTAssertEqual(commands[0].arguments, [resources.installScript.path])
        XCTAssertEqual(commands[1].arguments, [resources.uninstallScript.path])
        XCTAssertTrue(commands.allSatisfy { $0.executable == URL(fileURLWithPath: "/bin/zsh") })
        XCTAssertTrue(commands.allSatisfy { $0.standardInput == nil })
    }

    func testPermissionProbeUsesBundledMCPWithNoArguments() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let binary = root.appendingPathComponent("dist/NovaComputerUsePlugin/bin/NovaComputerUseMCP")
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        let runner = RecordingRunner()

        try await NovaInstaller(resources: NovaResources(root: root), runner: runner).probePermissions()
        let command = await runner.commands.first

        XCTAssertEqual(command?.executable, binary)
        XCTAssertEqual(command?.arguments, [])
        XCTAssertTrue(String(decoding: command?.standardInput ?? Data(), as: UTF8.self).contains("get_app_state"))
        XCTAssertTrue(String(decoding: command?.standardInput ?? Data(), as: UTF8.self).contains("TextEdit"))
    }

    func testDiagnosticsRedactHomeDirectory() {
        let value = NovaDiagnostics.redact(
            "helper failed at /Users/theodore/Library/Caches/Nova",
            homeDirectory: URL(fileURLWithPath: "/Users/theodore")
        )
        XCTAssertEqual(value, "helper failed at ~/Library/Caches/Nova")
    }
}

private actor RecordingRunner: NovaCommandRunning {
    private(set) var commands: [NovaCommand] = []

    func run(_ command: NovaCommand) async throws -> NovaCommandResult {
        commands.append(command)
        return NovaCommandResult(output: "ok", errorOutput: "", exitCode: 0)
    }
}
