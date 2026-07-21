import Foundation
import Security

public enum ServiceSocketSessionError: Error, Sendable, Equatable {
    case authenticationFailed
    case peerIdentityRejected
}

public enum ServiceSocketSession {
    public static let challengeByteCount = 32
    public static let defaultConnectionTimeout: TimeInterval = 30
    public static let defaultAuthenticationTimeout: TimeInterval = 5
    public static let defaultIdleTimeout: TimeInterval = 120
    private static let maximumResponseSize = 1 * 1024 * 1024

    public static func run(
        socketPath: String,
        expectedPeerCodeURL: URL,
        dispatcher: ServiceDispatcher,
        peerVerifier: any PeerProcessIdentityVerifying = CodeSignaturePeerVerifier(),
        connectionTimeout: TimeInterval = defaultConnectionTimeout,
        authenticationTimeout: TimeInterval = defaultAuthenticationTimeout,
        idleTimeout: TimeInterval = defaultIdleTimeout
    ) async throws {
        try await run(
            socketPath: socketPath,
            expectedPeerCodeURL: expectedPeerCodeURL,
            dispatcher: dispatcher,
            peerVerifier: peerVerifier,
            challengeGenerator: makeSecureChallenge,
            connectionTimeout: connectionTimeout,
            authenticationTimeout: authenticationTimeout,
            idleTimeout: idleTimeout
        )
    }

    static func run(
        socketPath: String,
        expectedPeerCodeURL: URL,
        dispatcher: ServiceDispatcher,
        peerVerifier: any PeerProcessIdentityVerifying,
        challengeGenerator: @escaping @Sendable () throws -> Data,
        connectionTimeout: TimeInterval,
        authenticationTimeout: TimeInterval,
        idleTimeout: TimeInterval
    ) async throws {
        defer { dispatcher.cleanup() }
        let connection = try await UnixSocketIPC.connect(
            path: socketPath,
            deadline: Date().addingTimeInterval(max(0.001, connectionTimeout))
        )
        defer { connection.close() }

        let peerProcessIdentifier = try connection.peerProcessIdentifier()
        guard peerVerifier.isValidPeer(
            processIdentifier: peerProcessIdentifier,
            expectedCodeAt: expectedPeerCodeURL
        ) else {
            throw ServiceSocketSessionError.peerIdentityRejected
        }

        let challenge = try challengeGenerator()
        guard challenge.count == challengeByteCount else {
            throw ServiceSocketSessionError.authenticationFailed
        }
        let authenticationDeadline = Date().addingTimeInterval(max(0.001, authenticationTimeout))
        do {
            try await connection.writeFrame(challenge, deadline: authenticationDeadline)
            let response = try await connection.readFrame(deadline: authenticationDeadline)
            guard response.count == challengeByteCount * 2,
                  securelyMatches(Data(response.prefix(challengeByteCount)), challenge) else {
                throw ServiceSocketSessionError.authenticationFailed
            }
            let peerChallenge = Data(response.suffix(challengeByteCount))
            try await connection.writeFrame(peerChallenge, deadline: authenticationDeadline)
        } catch let error as ServiceSocketSessionError {
            throw error
        } catch {
            throw ServiceSocketSessionError.authenticationFailed
        }

        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        while !Task.isCancelled {
            let requestData: Data
            do {
                requestData = try await connection.readFrame(
                    deadline: Date().addingTimeInterval(max(0.001, idleTimeout))
                )
            } catch UnixSocketIPCError.timedOut {
                return
            } catch {
                return
            }

            if requestData.isEmpty {
                do {
                    try await connection.writeFrame(
                        Data(),
                        deadline: Date().addingTimeInterval(max(0.001, authenticationTimeout))
                    )
                } catch {
                    return
                }
                continue
            }

            let response: ServiceResponse
            if let request = try? decoder.decode(ServiceRequest.self, from: requestData) {
                response = await dispatcher.handle(request)
            } else {
                response = .failure(
                    id: "",
                    ServiceError(code: .invalidRequest, message: "Invalid request")
                )
            }
            guard var responseData = try? encoder.encode(response) else { return }
            if responseData.count > maximumResponseSize {
                responseData = (try? encoder.encode(ServiceResponse.failure(
                    id: response.id,
                    ServiceError(code: .internalError, message: "Response exceeds maximum size")
                ))) ?? Data()
            }
            do {
                try await connection.writeFrame(
                    responseData,
                    deadline: Date().addingTimeInterval(max(0.001, authenticationTimeout))
                )
            } catch {
                return
            }
        }
    }

    public static func makeSecureChallenge() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: challengeByteCount)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ServiceSocketSessionError.authenticationFailed
        }
        return Data(bytes)
    }

    public static func securelyMatches(_ left: Data, _ right: Data) -> Bool {
        guard left.count == right.count else { return false }
        var difference: UInt8 = 0
        for (leftByte, rightByte) in zip(left, right) {
            difference |= leftByte ^ rightByte
        }
        return difference == 0
    }
}
