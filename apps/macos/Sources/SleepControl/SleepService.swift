import Foundation
import Security
import Darwin

@objc public protocol SleepServiceProtocol {
    /// The reply arrives after the session has ended and restoration was attempted.
    func run(lease: String, token: String, withReply reply: @escaping (String) -> Void)
}

public enum SleepService {
    public static let name = "app.neuraos.native.sleep"
    public static let plist = name + ".plist"
    public static let stateDirectory = "/Library/Application Support/neuraOS Sleep Control"

    /// Pin the peer to the designated requirement of the bundled executable.
    /// Ad-hoc builds use its exact cdhash; Developer ID builds retain their identity
    /// across updates. Never accept a bundle identifier alone.
    public static func requirement(for url: URL) throws -> String {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        var text: CFString?
        var result = SecStaticCodeCreateWithPath(url as CFURL, [], &code)
        if result == errSecSuccess, let code {
            result = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil)
            if result == errSecSuccess {result = SecCodeCopyDesignatedRequirement(code, [], &requirement)}
        }
        if result == errSecSuccess, let requirement {result = SecRequirementCopyString(requirement, [], &text)}
        guard result == errSecSuccess, let text else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result == errSecSuccess ? errSecCSUnsigned : result))
        }
        return text as String
    }

    public static func validRequest(lease: String, token: String, owner: uid_t) -> Bool {
        owner > 0 && lease.hasPrefix("/") && lease.utf8.count < 1024 && !lease.contains("\0") && UUID(uuidString: token) != nil
    }

}
