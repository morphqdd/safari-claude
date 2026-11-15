import Foundation
import Security

public final class Auth {
    private let paths: Paths.Type

    public init(paths: Paths.Type = Paths.self) {
        self.paths = paths
    }

    /// Returns the persisted token, creating it (32 random bytes, hex, mode 0600) if absent.
    public func loadOrCreateToken() throws -> String {
        let fm = FileManager.default
        let file = paths.token
        if let data = try? Data(contentsOf: file),
           let s = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
           s.count == 64 {
            return s
        }
        try fm.createDirectory(at: paths.support, withIntermediateDirectories: true)
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw RPCError.`internal`("random generation failed")
        }
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        guard fm.createFile(atPath: file.path, contents: Data(token.utf8), attributes: [.posixPermissions: 0o600]) else {
            throw RPCError.`internal`("cannot write token file")
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return token
    }

    public func authorize(hello: Message, origin: String?) -> Bool {
        guard case .hello(let role, let token) = hello else { return false }
        switch role {
        case .extension_:
            return origin?.hasPrefix("safari-web-extension://") ?? false
        case .mcp:
            guard let token, let expected = try? loadOrCreateToken() else { return false }
            return Self.constantTimeEqual(token, expected)
        }
    }

    private static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }
}
