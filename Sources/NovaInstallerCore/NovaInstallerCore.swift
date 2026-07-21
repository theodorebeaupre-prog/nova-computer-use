import Foundation

public struct NovaHealthReport: Sendable, Equatable {
    public let macOSSupported: Bool
    public let architectureSupported: Bool
    public let architecture: String
    public let codexAvailable: Bool
    public let pluginInstalled: Bool
    public let pluginEnabled: Bool

    public var readyForInstallation: Bool {
        macOSSupported && architectureSupported && codexAvailable
    }

    public var healthy: Bool {
        readyForInstallation && pluginInstalled && pluginEnabled
    }
}

public enum NovaInspector {
    public static func inspectCurrentSystem() -> NovaHealthReport {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var paths = (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin")
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)).appendingPathComponent("codex").path }
        paths += [
            home.appendingPathComponent(".local/bin/codex").path,
            "/usr/local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/Applications/Codex.app/Contents/MacOS/Codex"
        ]
        return inspect(
            homeDirectory: home,
            executableSearchPaths: paths,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersion,
            architecture: currentArchitecture
        )
    }

    public static func inspect(
        homeDirectory: URL,
        executableSearchPaths: [String],
        operatingSystem: OperatingSystemVersion,
        architecture: String
    ) -> NovaHealthReport {
        let codexRoot = homeDirectory.appendingPathComponent(".codex", isDirectory: true)
        let plugin = codexRoot.appendingPathComponent("plugins/cache/nova/computer-use/1.0.0/bin/NovaComputerUseMCP")
        let config = codexRoot.appendingPathComponent("config.toml")
        let configText = (try? String(contentsOf: config, encoding: .utf8)) ?? ""
        return NovaHealthReport(
            macOSSupported: operatingSystem.majorVersion >= 15,
            architectureSupported: architecture == "x86_64" || architecture == "arm64",
            architecture: architecture,
            codexAvailable: executableSearchPaths.contains { FileManager.default.isExecutableFile(atPath: $0) },
            pluginInstalled: FileManager.default.fileExists(atPath: plugin.path),
            pluginEnabled: configText.contains("[plugins.\"computer-use@nova\"]") && configText.contains("enabled = true")
        )
    }

    private static var currentArchitecture: String {
        #if arch(x86_64)
        "x86_64"
        #elseif arch(arm64)
        "arm64"
        #else
        "unknown"
        #endif
    }
}

public struct NovaResources: Sendable {
    public let root: URL

    public init(root: URL) { self.root = root }

    public var installScript: URL { root.appendingPathComponent("scripts/install-local.sh") }
    public var uninstallScript: URL { root.appendingPathComponent("scripts/uninstall-local.sh") }
    public var pluginDirectory: URL { root.appendingPathComponent("dist/NovaComputerUsePlugin", isDirectory: true) }
}

public struct NovaCommand: Sendable, Equatable {
    public let executable: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let standardInput: Data?

    public init(executable: URL, arguments: [String], environment: [String: String] = [:], standardInput: Data? = nil) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.standardInput = standardInput
    }
}

public struct NovaCommandResult: Sendable, Equatable {
    public let output: String
    public let errorOutput: String
    public let exitCode: Int32

    public init(output: String, errorOutput: String, exitCode: Int32) {
        self.output = output
        self.errorOutput = errorOutput
        self.exitCode = exitCode
    }
}

public protocol NovaCommandRunning: Sendable {
    func run(_ command: NovaCommand) async throws -> NovaCommandResult
}

public enum NovaInstallerError: LocalizedError {
    case missingResource(String)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingResource(let name): "Nova ne trouve pas la ressource requise: \(name)."
        case .commandFailed(let details): "L’opération Nova a échoué. \(details)"
        }
    }
}

public actor FoundationCommandRunner: NovaCommandRunning {
    public init() {}

    public func run(_ command: NovaCommand) async throws -> NovaCommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let output = Pipe()
                let errors = Pipe()
                let input = Pipe()
                process.executableURL = command.executable
                process.arguments = command.arguments
                process.environment = ProcessInfo.processInfo.environment.merging(command.environment) { _, new in new }
                process.standardOutput = output
                process.standardError = errors
                process.standardInput = input
                do {
                    try process.run()
                    if let bytes = command.standardInput {
                        input.fileHandleForWriting.write(bytes)
                    }
                    try? input.fileHandleForWriting.close()
                    process.waitUntilExit()
                    continuation.resume(returning: NovaCommandResult(
                        output: String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                        errorOutput: String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self),
                        exitCode: process.terminationStatus
                    ))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

public struct NovaInstaller: Sendable {
    public let resources: NovaResources
    private let runner: any NovaCommandRunning

    public init(resources: NovaResources, runner: any NovaCommandRunning = FoundationCommandRunner()) {
        self.resources = resources
        self.runner = runner
    }

    public func install() async throws { try await execute(resources.installScript) }
    public func repair() async throws { try await install() }
    public func uninstall() async throws { try await execute(resources.uninstallScript) }

    public func probePermissions(appName: String = "TextEdit") async throws {
        let binary = resources.pluginDirectory.appendingPathComponent("bin/NovaComputerUseMCP")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw NovaInstallerError.missingResource("NovaComputerUseMCP")
        }
        let safeName = appName.replacingOccurrences(of: "\"", with: "")
        let input = [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"nova-installer","version":"1.0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list_apps","arguments":{}}}"#,
            "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"get_app_state\",\"arguments\":{\"app\":\"\(safeName)\"}}}"
        ].joined(separator: "\n") + "\n"
        let result = try await runner.run(NovaCommand(
            executable: binary,
            arguments: [],
            standardInput: Data(input.utf8)
        ))
        let combined = result.output + "\n" + result.errorOutput
        guard result.exitCode == 0, !combined.contains("permission_denied"), !combined.contains("\"isError\":true") else {
            throw NovaInstallerError.commandFailed(NovaDiagnostics.redact(combined))
        }
    }

    private func execute(_ script: URL) async throws {
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw NovaInstallerError.missingResource(script.lastPathComponent)
        }
        let result = try await runner.run(NovaCommand(executable: URL(fileURLWithPath: "/bin/zsh"), arguments: [script.path]))
        guard result.exitCode == 0 else {
            let detail = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NovaInstallerError.commandFailed(detail.isEmpty ? "Code \(result.exitCode)." : detail)
        }
    }
}

public enum NovaDiagnostics {
    public static func redact(_ value: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        value.replacingOccurrences(of: homeDirectory.path, with: "~")
    }
}
