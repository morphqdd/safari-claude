import Testing
import Foundation
@testable import HelperCore

private func tempRoot() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("sc-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

@Suite(.serialized) struct AuthTests {
    @Test func tokenCreatedWith0600AndStable() throws {
        Paths.root = tempRoot()
        let auth = Auth()
        let a = try auth.loadOrCreateToken()
        let b = try auth.loadOrCreateToken()
        #expect(a == b)
        #expect(a.count == 64)
        #expect(a.allSatisfy { $0.isHexDigit })
        let attrs = try FileManager.default.attributesOfItem(atPath: Paths.token.path)
        #expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func mcpRequiresToken() throws {
        Paths.root = tempRoot()
        let auth = Auth()
        let token = try auth.loadOrCreateToken()
        #expect(!auth.authorize(hello: .hello(role: .mcp, token: "wrong"), origin: nil))
        #expect(!auth.authorize(hello: .hello(role: .mcp, token: nil), origin: nil))
        #expect(auth.authorize(hello: .hello(role: .mcp, token: token), origin: nil))
    }

    @Test func extensionOriginAccepted() {
        let auth = Auth()
        let hello = Message.hello(role: .extension_, token: nil)
        #expect(auth.authorize(hello: hello, origin: "safari-web-extension://aaa"))
        #expect(auth.authorize(hello: hello, origin: "safari-web-extension://bbb"))
        #expect(!auth.authorize(hello: hello, origin: "https://evil.com"))
        #expect(!auth.authorize(hello: hello, origin: nil))
    }
}
