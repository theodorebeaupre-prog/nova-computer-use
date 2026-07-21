import Foundation
import Security

public protocol PeerProcessIdentityVerifying: Sendable {
    func isValidPeer(processIdentifier: pid_t, expectedCodeAt url: URL) -> Bool
}

public struct CodeSignaturePeerVerifier: PeerProcessIdentityVerifying {
    public init() {}

    public func isValidPeer(processIdentifier: pid_t, expectedCodeAt url: URL) -> Bool {
        guard processIdentifier > 0 else { return false }

        var peerCode: SecCode?
        let attributes = [kSecGuestAttributePid as String: processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &peerCode) == errSecSuccess,
              let peerCode else { return false }

        var expectedCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &expectedCode) == errSecSuccess,
              let expectedCode else { return false }

        let staticValidation = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(expectedCode, staticValidation, nil) == errSecSuccess else {
            return false
        }

        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(expectedCode, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement else { return false }
        let dynamicValidation = SecCSFlags(rawValue: kSecCSStrictValidate)
        guard SecCodeCheckValidity(peerCode, dynamicValidation, requirement) == errSecSuccess else {
            return false
        }

        var peerStaticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(peerCode, SecCSFlags(), &peerStaticCode) == errSecSuccess,
              let peerStaticCode else { return false }
        var peerCodeURL: CFURL?
        guard SecCodeCopyPath(peerStaticCode, SecCSFlags(), &peerCodeURL) == errSecSuccess,
              let peerCodeURL else { return false }

        return Self.canonical(peerCodeURL as URL) == Self.canonical(url)
    }

    private static func canonical(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }
}
