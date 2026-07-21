@preconcurrency import Foundation
import Darwin
import NovaComputerUseCore

struct ChildShutdownTimeouts: Sendable, Equatable {
    let graceful: TimeInterval
    let terminate: TimeInterval
    let kill: TimeInterval

    static let `default` = ChildShutdownTimeouts(graceful: 1, terminate: 1, kill: 1)
}

protocol ServiceChildProcess: AnyObject, Sendable {
    var isRunning: Bool { get }
    var processIdentifier: Int32 { get }
    func start() throws
    func waitForExit(timeout: TimeInterval) -> Bool
    func terminate()
    func kill()
}

private final class FoundationServiceChildProcess: ServiceChildProcess, @unchecked Sendable {
    private let process: Process
    private let exitSignal = DispatchSemaphore(value: 0)

    init(executableURL: URL, arguments: [String], input: Pipe, output: Pipe) {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.standardError
        self.process = process
        process.terminationHandler = { [exitSignal] _ in exitSignal.signal() }
    }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: Int32 { process.processIdentifier }

    func start() throws {
        try process.run()
    }

    func waitForExit(timeout: TimeInterval) -> Bool {
        guard process.isRunning else { return true }
        let result = exitSignal.wait(timeout: .now() + timeout)
        return result == .success || !process.isRunning
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
    }

    func kill() {
        guard process.isRunning else { return }
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
    }
}

actor ServiceProcessTransport: ServiceTransport {
    private static let maximumResponseLineSize = 1 * 1024 * 1024
    private static let responseReadChunkSize = 64 * 1024
    private static let responsePollMilliseconds: Int32 = 50

    private let process: any ServiceChildProcess
    private let requestInput: FileHandle
    private let responseOutput: FileHandle
    private let shutdownTimeouts: ChildShutdownTimeouts
    private let responseTimeout: TimeInterval
    private var responseBuffer = Data()
    private var isShutDown = false
    private var isBroken = false
    private var isCallInProgress = false

    init(
        executableURL: URL,
        arguments: [String] = [],
        shutdownTimeouts: ChildShutdownTimeouts = .default,
        responseTimeout: TimeInterval = 30
    ) throws {
        signal(SIGPIPE, SIG_IGN)
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let process = FoundationServiceChildProcess(
            executableURL: executableURL,
            arguments: arguments,
            input: inputPipe,
            output: outputPipe
        )

        self.process = process
        requestInput = inputPipe.fileHandleForWriting
        responseOutput = outputPipe.fileHandleForReading
        self.shutdownTimeouts = shutdownTimeouts
        self.responseTimeout = responseTimeout

        do {
            try process.start()
        } catch {
            try? requestInput.close()
            try? responseOutput.close()
            try? inputPipe.fileHandleForReading.close()
            try? outputPipe.fileHandleForWriting.close()
            throw ServiceError(
                code: .internalError,
                message: "Unable to launch NovaComputerUseService"
            )
        }

        try? inputPipe.fileHandleForReading.close()
        try? outputPipe.fileHandleForWriting.close()
    }

    init(
        process: any ServiceChildProcess,
        requestInput: FileHandle,
        responseOutput: FileHandle,
        shutdownTimeouts: ChildShutdownTimeouts = .default,
        responseTimeout: TimeInterval = 30
    ) throws {
        signal(SIGPIPE, SIG_IGN)
        self.process = process
        self.requestInput = requestInput
        self.responseOutput = responseOutput
        self.shutdownTimeouts = shutdownTimeouts
        self.responseTimeout = responseTimeout
        do {
            try process.start()
        } catch {
            try? requestInput.close()
            try? responseOutput.close()
            throw ServiceError(code: .internalError, message: "Unable to launch NovaComputerUseService")
        }
    }

    var childProcessIdentifier: Int32 { process.processIdentifier }

    func call(operation: ServiceOperation, arguments: [String: JSONValue]) async throws -> JSONValue {
        guard !isShutDown, !isBroken, process.isRunning else { throw childExitedError }
        guard !isCallInProgress else {
            throw ServiceError(code: .internalError, message: "Concurrent service calls are unsupported")
        }
        isCallInProgress = true
        defer { isCallInProgress = false }

        let id = UUID().uuidString
        var request = try JSONEncoder().encode(ServiceRequest(id: id, operation: operation, arguments: arguments))
        request.append(0x0A)
        do {
            try requestInput.write(contentsOf: request)
        } catch {
            throw childExitedError
        }

        let line: Data
        do {
            line = try await readResponseLine()
        } catch {
            isBroken = true
            try? responseOutput.close()
            throw error
        }
        guard !isShutDown else { throw childExitedError }
        let response: ServiceResponse
        do {
            response = try JSONDecoder().decode(ServiceResponse.self, from: line)
        } catch {
            throw ServiceError(code: .internalError, message: "Invalid response from NovaComputerUseService")
        }
        guard response.id == id else {
            throw ServiceError(code: .internalError, message: "Mismatched response from NovaComputerUseService")
        }

        switch response {
        case .success(_, let result):
            return result
        case .failure(_, let error):
            throw error
        }
    }

    func shutdown() {
        guard !isShutDown else { return }
        isShutDown = true
        try? requestInput.close()
        // Closing the read side interrupts an in-flight silent call before the bounded process
        // escalation below. `readResponseLine` yields between short poll intervals so shutdown can
        // enter this actor even while a response is pending.
        try? responseOutput.close()

        // EOF gives the service a bounded chance to clean up. Each escalation also has a hard
        // bound: adapter shutdown never performs an unbounded process wait.
        if process.waitForExit(timeout: shutdownTimeouts.graceful) {
            return
        }
        if process.isRunning {
            process.terminate()
        }
        if process.waitForExit(timeout: shutdownTimeouts.terminate) {
            return
        }
        if process.isRunning {
            process.kill()
        }
        _ = process.waitForExit(timeout: shutdownTimeouts.kill)
    }

    private func readResponseLine() async throws -> Data {
        let deadline = Date().addingTimeInterval(responseTimeout)
        while true {
            if let newline = responseBuffer.firstIndex(of: 0x0A) {
                guard newline <= Self.maximumResponseLineSize else { throw oversizedResponseError }
                let line = Data(responseBuffer[..<newline])
                responseBuffer.removeSubrange(...newline)
                return line
            }
            guard responseBuffer.count <= Self.maximumResponseLineSize else {
                throw oversizedResponseError
            }
            guard !Task.isCancelled, !isShutDown else { throw childExitedError }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw responseTimeoutError }
            let remainingMilliseconds = Int32(max(1, min(
                Double(Self.responsePollMilliseconds),
                remaining * 1_000
            )))
            var descriptor = pollfd(
                fd: responseOutput.fileDescriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let pollResult = Darwin.poll(&descriptor, 1, remainingMilliseconds)
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw childExitedError
            }
            if pollResult == 0 {
                await Task.yield()
                continue
            }

            var bytes = [UInt8](repeating: 0, count: Self.responseReadChunkSize)
            let count = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(responseOutput.fileDescriptor, buffer.baseAddress, buffer.count)
            }
            guard count > 0 else { throw childExitedError }
            responseBuffer.append(contentsOf: bytes.prefix(count))
            await Task.yield()
        }
    }

    private var childExitedError: ServiceError {
        ServiceError(code: .internalError, message: "NovaComputerUseService exited")
    }

    private var responseTimeoutError: ServiceError {
        ServiceError(code: .internalError, message: "NovaComputerUseService response timed out")
    }

    private var oversizedResponseError: ServiceError {
        ServiceError(code: .internalError, message: "NovaComputerUseService response exceeds maximum size")
    }
}

protocol ServiceApplicationLaunch: AnyObject, Sendable {
    var isRunning: Bool { get }
    func terminate()
}

protocol ServiceApplicationLaunching: Sendable {
    func launch(applicationURL: URL, arguments: [String]) throws -> any ServiceApplicationLaunch
}

private final class FoundationServiceApplicationLaunch: ServiceApplicationLaunch, @unchecked Sendable {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    var isRunning: Bool { process.isRunning }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}

private struct FoundationServiceApplicationLauncher: ServiceApplicationLaunching {
    func launch(applicationURL: URL, arguments: [String]) throws -> any ServiceApplicationLaunch {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.standardError
        try process.run()
        return FoundationServiceApplicationLaunch(process: process)
    }
}

actor ServiceApplicationTransport: ServiceTransport {
    private let applicationURL: URL
    private let ipcRoot: URL
    private let removesIPCRootOnShutdown: Bool
    private let launcher: any ServiceApplicationLaunching
    private let responseTimeout: TimeInterval
    private var currentLauncher: (any ServiceApplicationLaunch)?
    private var currentListener: UnixSocketListener?
    private var currentConnection: UnixSocketConnection?
    private var isShutDown = false
    private var isCallInProgress = false

    init(
        applicationURL: URL,
        ipcRoot: URL? = nil,
        launcher: any ServiceApplicationLaunching = FoundationServiceApplicationLauncher(),
        responseTimeout: TimeInterval = 30
    ) throws {
        self.applicationURL = applicationURL
        self.launcher = launcher
        self.responseTimeout = responseTimeout
        removesIPCRootOnShutdown = ipcRoot == nil
        self.ipcRoot = ipcRoot ?? URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("ncu-\(UUID().uuidString.prefix(12))", isDirectory: true)
        try FileManager.default.createDirectory(
            at: self.ipcRoot,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard Darwin.chmod(self.ipcRoot.path, 0o700) == 0 else {
            throw ServiceError(code: .internalError, message: "Unable to create NovaComputerUse IPC directory")
        }
    }

    func call(operation: ServiceOperation, arguments: [String: JSONValue]) async throws -> JSONValue {
        guard !isShutDown else { throw serviceExitedError }
        guard !isCallInProgress else {
            throw ServiceError(code: .internalError, message: "Concurrent service calls are unsupported")
        }
        isCallInProgress = true
        defer { isCallInProgress = false }
        let callDirectory = ipcRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: callDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: callDirectory) }

        let id = UUID().uuidString
        let socketURL = callDirectory.appendingPathComponent("s")
        let listener = try UnixSocketListener(socketURL: socketURL)
        currentListener = listener
        let token = UUID().uuidString
        let request = try JSONEncoder().encode(ServiceRequest(id: id, operation: operation, arguments: arguments))
        let launchArguments = [
            "-W", "-n", "-a", applicationURL.path, "--args",
            "--ipc-socket", socketURL.path,
            "--ipc-token", token
        ]

        let launchedApplication: any ServiceApplicationLaunch
        do {
            launchedApplication = try launcher.launch(applicationURL: applicationURL, arguments: launchArguments)
        } catch {
            currentLauncher = nil
            throw serviceExitedError
        }
        currentLauncher = launchedApplication
        defer {
            currentConnection?.close()
            currentConnection = nil
            currentListener?.close()
            currentListener = nil
            if launchedApplication.isRunning { launchedApplication.terminate() }
            currentLauncher = nil
        }

        let deadline = Date().addingTimeInterval(responseTimeout)
        do {
            let connection = try await listener.accept(deadline: deadline)
            currentConnection = connection
            let presentedToken = try await connection.readExactly(token.utf8.count, deadline: deadline)
            guard presentedToken == Data(token.utf8) else {
                throw ServiceError(code: .internalError, message: "Invalid response from NovaComputerUseService")
            }
            try await connection.writeFrame(request, deadline: deadline)
            let responseData = try await connection.readFrame(deadline: deadline)
            guard let response = try? JSONDecoder().decode(ServiceResponse.self, from: responseData),
                  response.id == id else {
                throw ServiceError(code: .internalError, message: "Invalid response from NovaComputerUseService")
            }
            switch response {
            case .success(_, let result): return result
            case .failure(_, let error): throw error
            }
        } catch UnixSocketIPCError.timedOut {
            throw isShutDown ? serviceExitedError : ServiceError(
                code: .internalError,
                message: "NovaComputerUseService response timed out"
            )
        } catch let error as ServiceError {
            throw error
        } catch {
            throw isShutDown ? serviceExitedError : ServiceError(
                code: .internalError,
                message: "Invalid response from NovaComputerUseService"
            )
        }
    }

    func shutdown() {
        isShutDown = true
        currentConnection?.close()
        currentConnection = nil
        currentListener?.close()
        currentListener = nil
        currentLauncher?.terminate()
        currentLauncher = nil
        if removesIPCRootOnShutdown { try? FileManager.default.removeItem(at: ipcRoot) }
    }

    private var serviceExitedError: ServiceError {
        ServiceError(code: .internalError, message: "NovaComputerUseService exited")
    }
}

private final class TerminationSignals: @unchecked Sendable {
    private let sources: [DispatchSourceSignal]

    init(input: FileHandle, onTermination: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        sources = [SIGINT, SIGTERM].map { signalNumber in
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler {
                try? input.close()
                onTermination()
            }
            source.resume()
            return source
        }
    }
}

func siblingServiceURL(adapterURL: URL) -> URL {
    adapterURL.deletingLastPathComponent()
        .appendingPathComponent("NovaComputerUseService.app", isDirectory: true)
        .appendingPathComponent("Contents/MacOS/NovaComputerUseService")
}

func siblingServiceApplicationURL(adapterURL: URL) -> URL {
    adapterURL.deletingLastPathComponent()
        .appendingPathComponent("NovaComputerUseService.app", isDirectory: true)
}

private func siblingServiceURL() -> URL {
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let adapter = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: currentDirectory)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    return siblingServiceURL(adapterURL: adapter)
}

do {
    signal(SIGPIPE, SIG_IGN)
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let adapter = URL(fileURLWithPath: CommandLine.arguments[0], relativeTo: currentDirectory)
        .standardizedFileURL
        .resolvingSymlinksInPath()
    let transport = try ServiceApplicationTransport(applicationURL: siblingServiceApplicationURL(adapterURL: adapter))
    let terminationSignals = TerminationSignals(input: .standardInput) {
        Task { await transport.shutdown() }
    }
    _ = terminationSignals
    await MCPStdio.run(
        input: .standardInput,
        output: .standardOutput,
        server: MCPServer(transport: transport)
    )
    withExtendedLifetime(terminationSignals) {}
    await transport.shutdown()
} catch {
    FileHandle.standardError.write(Data("NovaComputerUseMCP: unable to start service\n".utf8))
    exit(EXIT_FAILURE)
}
