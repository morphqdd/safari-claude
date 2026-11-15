import Testing
import Foundation
@testable import HelperCore

final class FakeConnection: Connection, @unchecked Sendable {
    var origin: String?
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let lock = NSLock()
    private var _sent: [String] = []
    private var _closed: [UInt16] = []
    init(origin: String? = nil) { self.origin = origin }
    var sent: [Message] {
        lock.lock(); defer { lock.unlock() }
        return _sent.compactMap { try? JSONDecoder().decode(Message.self, from: Data($0.utf8)) }
    }
    var closed: [UInt16] { lock.lock(); defer { lock.unlock() }; return _closed }
    func send(_ text: String) { lock.lock(); _sent.append(text); lock.unlock() }
    func close(code: UInt16) { lock.lock(); _closed.append(code); lock.unlock() }
    func receive(_ m: Message) {
        let s = String(data: try! JSONEncoder().encode(m), encoding: .utf8)!
        onText?(s)
    }
    func disconnect() { onClose?() }
}

actor Gate {
    private var cont: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { cont = $0 } }
    func open() { cont?.resume(); cont = nil }
}

struct FakeTools: ToolHandling {
    var handler: @Sendable (String, JSON, ExtensionLink) async throws -> JSON = { _, args, _ in args }
    func call(name: String, arguments: JSON, link: ExtensionLink) async throws -> JSON {
        try await handler(name, arguments, link)
    }
}

private func eventually(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return cond()
}

private func tempAuth() -> (Auth, String) {
    Paths.root = FileManager.default.temporaryDirectory.appendingPathComponent("sc-\(UUID().uuidString)")
    let a = Auth()
    return (a, try! a.loadOrCreateToken())
}

private func call(_ id: Int, _ name: String = "t", args: JSON = .object([:])) -> Message {
    .req(id: id, method: "tool.call", params: .object(["name": .string(name), "arguments": args]))
}

private let stopMessage = "Пользователь нажал «Стоп». Не повторяй действие — спроси пользователя, что делать дальше."

private func errorMessage(_ c: FakeConnection, id: Int) -> String? {
    for m in c.sent { if case .res(let i, _, let e) = m, i == id { return e?.message } }
    return nil
}

private func errorCode(_ c: FakeConnection, id: Int) -> String? {
    for m in c.sent { if case .res(let i, _, let e) = m, i == id { return e?.code } }
    return nil
}

@Suite(.serialized) struct DaemonTests {
    func mcp(_ d: Daemon, _ token: String) async -> FakeConnection {
        let c = FakeConnection()
        d.accept(c)
        c.receive(.hello(role: .mcp, token: token))
        _ = await eventually { c.sent.contains(.welcome) }
        return c
    }
    func ext(_ d: Daemon) async -> FakeConnection {
        let c = FakeConnection(origin: "safari-web-extension://abc")
        d.accept(c)
        c.receive(.hello(role: .extension_, token: nil))
        _ = await eventually { c.sent.contains(.welcome) }
        return c
    }

    @Test func rejectsBadHello() async {
        let (auth, _) = tempAuth()
        let d = Daemon(auth: auth, tools: FakeTools(), exit: {})
        let c = FakeConnection()
        d.accept(c)
        c.receive(.hello(role: .mcp, token: "wrong"))
        #expect(await eventually { c.closed == [4001] })
    }

    @Test func statusReportsExtensionConnection() async {
        let (auth, token) = tempAuth()
        let d = Daemon(auth: auth, tools: FakeTools(), axTrusted: { true }, exit: {})
        let m = await mcp(d, token)
        m.receive(.req(id: 1, method: "status", params: .object([:])))
        #expect(await eventually { m.sent.contains(.res(id: 1, result: .object(["extensionConnected": .bool(false), "axTrusted": .bool(true)]), error: nil)) })
        _ = await ext(d)
        m.receive(.req(id: 2, method: "status", params: .object([:])))
        #expect(await eventually { m.sent.contains(.res(id: 2, result: .object(["extensionConnected": .bool(true), "axTrusted": .bool(true)]), error: nil)) })
    }

    @Test func routesToolCallToHandler() async {
        let (auth, token) = tempAuth()
        let d = Daemon(auth: auth, tools: FakeTools(), exit: {})
        let c = await mcp(d, token)
        c.receive(call(7, args: .object(["x": .number(1)])))
        #expect(await eventually { c.sent.contains(.res(id: 7, result: .object(["x": .number(1)]), error: nil)) })
    }

    @Test func secondClientGetsBusy() async {
        let (auth, token) = tempAuth()
        let d = Daemon(auth: auth, tools: FakeTools(), exit: {})
        let a = await mcp(d, token), b = await mcp(d, token)
        a.receive(call(1))
        #expect(await eventually { !a.sent.filter { if case .res = $0 { return true }; return false }.isEmpty })
        b.receive(call(2))
        #expect(await eventually { errorCode(b, id: 2) == "busy" })
    }

    @Test func stopCancelsInFlightAndStaysCancelledUntilLockIdle() async {
        let (auth, token) = tempAuth()
        let gate = Gate()
        let d = Daemon(auth: auth, tools: FakeTools(handler: { name, args, _ in if name == "slow" { await gate.wait() }; return args }),
                       lockIdle: 0.5, exit: {})
        let e = await ext(d)
        let a = await mcp(d, token), b = await mcp(d, token)
        a.receive(call(1, "slow"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        e.receive(.event(name: "stop", data: .object([:])))
        #expect(await eventually { errorCode(a, id: 1) == "cancelled" })
        await gate.open()
        // every later call from the owner is cancelled; other sessions stay busy
        for id in 2...4 {
            a.receive(call(id))
            #expect(await eventually { errorCode(a, id: id) == "cancelled" })
            #expect(errorMessage(a, id: id) == stopMessage)
        }
        b.receive(call(5))
        #expect(await eventually { errorCode(b, id: 5) == "busy" })
        #expect(!e.sent.contains(.event(name: "idle", data: .object([:]))))
        // lockIdle expiry releases the lock
        #expect(await eventually { e.sent.contains(.event(name: "idle", data: .object([:]))) })
        a.receive(call(6))
        #expect(await eventually { a.sent.contains(.res(id: 6, result: .object([:]), error: nil)) })
    }

    @Test func stopWithNothingInFlightCancelsNextCalls() async {
        let (auth, token) = tempAuth()
        let d = Daemon(auth: auth, tools: FakeTools(), exit: {})
        let e = await ext(d)
        let a = await mcp(d, token)
        a.receive(call(1))
        #expect(await eventually { a.sent.contains(.res(id: 1, result: .object([:]), error: nil)) })
        e.receive(.event(name: "stop", data: .object([:])))
        try? await Task.sleep(nanoseconds: 50_000_000)
        a.receive(call(2))
        #expect(await eventually { errorCode(a, id: 2) == "cancelled" })
        a.receive(call(3))
        #expect(await eventually { errorCode(a, id: 3) == "cancelled" })
    }

    @Test func stopStateClearedOnOwnerDisconnect() async {
        let (auth, token) = tempAuth()
        let d = Daemon(auth: auth, tools: FakeTools(), exit: {})
        let e = await ext(d)
        let a = await mcp(d, token), b = await mcp(d, token)
        a.receive(call(1))
        _ = await eventually { a.sent.count > 1 }
        e.receive(.event(name: "stop", data: .object([:])))
        try? await Task.sleep(nanoseconds: 50_000_000)
        a.disconnect()
        try? await Task.sleep(nanoseconds: 50_000_000)
        b.receive(call(2))
        #expect(await eventually { b.sent.contains(.res(id: 2, result: .object([:]), error: nil)) })
    }

    @Test func stopFromReplacedExtensionIgnored() async {
        let (auth, token) = tempAuth()
        let gate = Gate()
        let d = Daemon(auth: auth, tools: FakeTools(handler: { name, args, _ in if name == "slow" { await gate.wait() }; return args }), exit: {})
        let old = await ext(d)
        let cur = await ext(d)
        let a = await mcp(d, token)
        a.receive(call(1, "slow"))
        try? await Task.sleep(nanoseconds: 100_000_000)
        old.receive(.event(name: "stop", data: .object([:])))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(errorCode(a, id: 1) == nil)
        cur.receive(.event(name: "stop", data: .object([:])))
        #expect(await eventually { errorCode(a, id: 1) == "cancelled" })
        await gate.open()
    }

    @Test func extensionRequestFailsFastWhenAbsent() async {
        let (auth, _) = tempAuth()
        let d = Daemon(auth: auth, tools: FakeTools(), exit: {})
        let start = Date()
        do { _ = try await d.link.request("ping", .object([:])); Issue.record("expected throw") }
        catch let e as RPCError { #expect(e.code == "no_extension") }
        catch { Issue.record("wrong error \(error)") }
        #expect(Date().timeIntervalSince(start) < 3.5)
    }

    @Test func extensionRequestDeliveredWhenConnectsLate() async throws {
        let (auth, _) = tempAuth()
        let d = Daemon(auth: auth, tools: FakeTools(), exit: {})
        let reqTask = Task { try await d.link.request("ping", .object(["a": .number(1)])) }
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let e = await ext(d)
        #expect(await eventually {
            e.sent.contains { if case .req(_, "ping", _) = $0 { return true }; return false }
        })
        for m in e.sent { if case .req(let id, _, _) = m { e.receive(.res(id: id, result: .string("pong"), error: nil)) } }
        #expect(try await reqTask.value == .string("pong"))
    }

    @Test func extensionDisconnectFailsInFlightRequest() async {
        let (auth, _) = tempAuth()
        let d = Daemon(auth: auth, tools: FakeTools(), exit: {})
        let e = await ext(d)
        let t = Task { try await d.link.request("ping", .object([:])) }
        _ = await eventually { e.sent.count > 1 }
        e.disconnect()
        do { _ = try await t.value; Issue.record("expected throw") }
        catch let err as RPCError { #expect(err.code == "no_extension") }
        catch { Issue.record("wrong error") }
    }

    @Test func idleExitAfterNoConnections() async throws {
        let (auth, _) = tempAuth()
        let fired = Box()
        _ = Daemon(auth: auth, tools: FakeTools(), idleExit: 0.2, exit: { fired.set() })
        #expect(await eventually { fired.value })

        let fired2 = Box()
        let d2 = Daemon(auth: auth, tools: FakeTools(), idleExit: 0.2, exit: { fired2.set() })
        let c = FakeConnection()
        d2.accept(c)
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(!fired2.value)
    }

    @Test func lockReleasedOnOwnerDisconnect() async {
        let (auth, token) = tempAuth()
        let d = Daemon(auth: auth, tools: FakeTools(), exit: {})
        let a = await mcp(d, token), b = await mcp(d, token)
        a.receive(call(1))
        _ = await eventually { a.sent.count > 1 }
        a.disconnect()
        try? await Task.sleep(nanoseconds: 100_000_000)
        b.receive(call(2))
        #expect(await eventually { b.sent.contains(.res(id: 2, result: .object([:]), error: nil)) })
    }

    @Test func lockReleasedAfterLockIdle() async {
        let (auth, token) = tempAuth()
        let d = Daemon(auth: auth, tools: FakeTools(), lockIdle: 0.2, exit: {})
        let a = await mcp(d, token), b = await mcp(d, token)
        a.receive(call(1))
        _ = await eventually { a.sent.count > 1 }
        try? await Task.sleep(nanoseconds: 500_000_000)
        b.receive(call(2))
        #expect(await eventually { b.sent.contains(.res(id: 2, result: .object([:]), error: nil)) })
    }
}

final class Box: @unchecked Sendable {
    private let l = NSLock(); private var v = false
    func set() { l.lock(); v = true; l.unlock() }
    var value: Bool { l.lock(); defer { l.unlock() }; return v }
}
