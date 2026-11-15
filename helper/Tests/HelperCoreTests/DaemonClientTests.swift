import Testing
import Foundation
@testable import HelperCore

private final class Counter: @unchecked Sendable {
    private let l = NSLock(); private var n = 0
    func next() -> Int { l.withLock { n += 1; return n } }
}

extension DaemonTests {
    /// Real daemon on an ephemeral TCP port.
    private func startDaemon(_ handler: @escaping @Sendable (String, JSON, ExtensionLink) async throws -> JSON)
        throws -> (Daemon, Listener, UInt16, String) {
        let auth = Auth(tokenFile: FileManager.default.temporaryDirectory
            .appendingPathComponent("sc-\(UUID().uuidString)").appendingPathComponent("token"))
        let token = try auth.loadOrCreateToken()
        let daemon = Daemon(auth: auth, tools: FakeTools(handler: handler), exit: {})
        let listener = try Listener.tcp(port: 0)
        listener.onConnection = { c in daemon.accept(c) }
        listener.start(queue: DispatchQueue(label: "test.dc.listener"))
        return (daemon, listener, listener.boundPort, token)
    }

    @Test func successfulCallReturnsDaemonResult() async throws {
        let (daemon, listener, port, token) = try startDaemon { name, args, _ in
            .object(["content": .array([.object(["type": .string("text"), "text": .string(name)])]), "isError": .bool(false)])
        }
        defer { withExtendedLifetime((daemon, listener)) {} }
        let client = DaemonClient(port: port, token: token)
        let r = try await client.call("tabs_list", .object([:]))
        #expect(r["isError"]?.bool == false)
        guard case .array(let c)? = r["content"] else { Issue.record("no content"); return }
        #expect(c[0]["text"]?.string == "tabs_list")
    }

    @Test func daemonErrorIsThrownAsRPCError() async throws {
        let (daemon, listener, port, token) = try startDaemon { _, _, _ in throw RPCError.noExtension() }
        defer { withExtendedLifetime((daemon, listener)) {} }
        let client = DaemonClient(port: port, token: token)
        do { _ = try await client.call("tabs_list", .object([:])); Issue.record("expected throw") }
        catch let e as RPCError { #expect(e.code == "no_extension") }
    }

    @Test func unreachableDaemonThrowsInternal() async {
        let client = DaemonClient(port: 1, token: "x")
        do { _ = try await client.call("tabs_list", .object([:])); Issue.record("expected throw") }
        catch let e as RPCError {
            #expect(e.code == "internal")
            #expect(e.message.hasPrefix("helper daemon unavailable"))
        } catch { Issue.record("wrong error \(error)") }
    }

    @Test func timeoutThenReconnects() async throws {
        let counter = Counter()
        let (daemon, listener, port, token) = try startDaemon { _, _, _ in
            if counter.next() == 1 { try? await Task.sleep(nanoseconds: 5_000_000_000) }
            return .object(["content": .array([]), "isError": .bool(false)])
        }
        defer { withExtendedLifetime((daemon, listener)) {} }
        let client = DaemonClient(port: port, token: token, timeout: 0.5)
        let start = Date()
        do { _ = try await client.call("tabs_list", .object([:])); Issue.record("expected timeout") }
        catch let e as RPCError { #expect(e.code == "timeout") }
        #expect(Date().timeIntervalSince(start) < 1.5)
        let r = try await client.call("tabs_list", .object([:]))
        #expect(r["isError"]?.bool == false)
    }
}
