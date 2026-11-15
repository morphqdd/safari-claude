import Testing
import Foundation
@testable import HelperCore

/// `ClaudeProcess` fake that is safe to inspect from the test thread while the daemon queue drives it.
final class LockedClaude: ClaudeProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var _written: [String] = []
    private var _terminated = false
    var onLine: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var stderrTail = ""
    func start() throws {}
    func write(_ line: String) { lock.withLock { _written.append(line) } }
    func terminate() { lock.withLock { _terminated = true } }
    var written: [String] { lock.withLock { _written } }
    var terminated: Bool { lock.withLock { _terminated } }
}

/// Daemon with a ChatSession on a fake launcher; records each launch's chat key.
final class DaemonChatHarness: @unchecked Sendable {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-dchat-\(UUID().uuidString)")
    private let lock = NSLock()
    private var _processes: [LockedClaude] = []
    private var _keys: [String] = []
    private var _toolCalls: [String] = []
    let token: String
    var daemon: Daemon!
    /// The daemon's queue and chat event handler, to inject events ChatSession cannot produce on cue.
    private var chatQueue: DispatchQueue?
    private var chatEmit: ((ChatEvent) -> Void)?

    init(lockIdle: TimeInterval = 120, idleExit: TimeInterval = 600, exit: @escaping () -> Void = {},
         tool: (@Sendable (String, JSON) async throws -> JSON)? = nil) {
        let dir = self.dir
        // Own token file: the global `Paths.root` is mutated by suites running in parallel.
        let auth = Auth(tokenFile: dir.appendingPathComponent("token"))
        token = try! auth.loadOrCreateToken()
        let tools = FakeTools(handler: { [unowned self] name, args, _ in
            lock.withLock { _toolCalls.append(name) }
            return try await tool?(name, args) ?? args
        })
        daemon = Daemon(auth: auth, tools: tools, idleExit: idleExit, lockIdle: lockIdle, chat: { [unowned self] q, emit in
            chatQueue = q
            chatEmit = emit
            return ChatSession(queue: q, launcher: { _, env, _ in
                let p = LockedClaude()
                self.lock.withLock {
                    self._processes.append(p)
                    self._keys.append(env["SC_CHAT_KEY"] ?? "")
                }
                return p
            }, claudePath: "/opt/claude", helperPath: "/h/safari-claude-helper", emit: emit,
               sessionFile: dir.appendingPathComponent("chat-session"),
               workspace: dir.appendingPathComponent("workspace", isDirectory: true))
        }, exit: exit)
    }

    deinit { try? FileManager.default.removeItem(at: dir) }

    var processes: [LockedClaude] { lock.withLock { _processes } }
    var key: String? { lock.withLock { _keys.last } }
    var toolCalls: [String] { lock.withLock { _toolCalls } }

    func mcp(chat: String? = nil) async -> FakeConnection {
        let c = FakeConnection()
        daemon.accept(c)
        c.receive(.hello(role: .mcp, token: token, chat: chat))
        _ = await eventually { c.sent.contains(.welcome) }
        return c
    }
    func ext() async -> FakeConnection {
        let c = FakeConnection(origin: "safari-web-extension://abc")
        daemon.accept(c)
        c.receive(.hello(role: .extension_, token: nil))
        _ = await eventually { c.sent.contains(.welcome) }
        return c
    }
    /// Sends chat.send and waits until claude got the text.
    func startTurn(_ e: FakeConnection, _ text: String = "hi") async {
        let written = processes.reduce(0) { $0 + $1.written.count }
        e.receive(.event(name: "chat.send", data: .object(["text": .string(text)])))
        _ = await eventually { self.processes.reduce(0) { $0 + $1.written.count } > written }
    }
    func endTurn() { processes.last?.onLine?(resultLine) }
    func emit(_ event: ChatEvent) { chatQueue!.sync { chatEmit!(event) } }
}

private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"sess-1","result":"Hi"}"#
private let empty: JSON = .object([:])

private func eventually(_ timeout: TimeInterval = 2, _ cond: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while Date() < end {
        if cond() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return cond()
}

private func call(_ id: Int, _ name: String = "t", args: JSON = .object([:])) -> Message {
    .req(id: id, method: "tool.call", params: .object(["name": .string(name), "arguments": args]))
}

private func response(_ c: FakeConnection, id: Int) -> (JSON?, RPCError?)? {
    for m in c.sent { if case .res(let i, let r, let e) = m, i == id { return (r, e) } }
    return nil
}

private func request(_ c: FakeConnection, _ method: String) -> (id: Int, params: JSON)? {
    for m in c.sent { if case .req(let id, let mt, let p) = m, mt == method { return (id, p) } }
    return nil
}

private func hasEvent(_ c: FakeConnection, _ name: String, _ data: JSON = .object([:])) -> Bool {
    c.sent.contains(.event(name: name, data: data))
}

private func idles(_ c: FakeConnection) -> Int {
    c.sent.filter { $0 == .event(name: "idle", data: .object([:])) }.count
}

@Suite(.serialized) struct DaemonChatTests {
    @Test func chatSendWhileTerminalOwnsLockIsBusy() async {
        let h = DaemonChatHarness()
        let e = await h.ext(), a = await h.mcp()
        a.receive(call(1))
        #expect(await eventually { response(a, id: 1) != nil })
        e.receive(.event(name: "chat.send", data: .object(["text": .string("hi")])))
        #expect(await eventually { hasEvent(e, "chat.busy") })
        #expect(h.processes.isEmpty)
    }

    @Test func chatSendStartsTurnAndReservesLock() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e, "открой почту")
        #expect(h.processes.count == 1)
        #expect(h.processes[0].written.last?.contains("открой почту") == true)
        let a = await h.mcp()
        a.receive(call(1))
        #expect(await eventually { response(a, id: 1)?.1?.code == "busy" })
    }

    @Test func terminalToolCallDuringChatTurnIsBusy() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        let a = await h.mcp()
        a.receive(call(1))
        #expect(await eventually { response(a, id: 1)?.1?.code == "busy" })
        #expect(h.toolCalls.isEmpty)
    }

    @Test func chatKeyedClientBecomesOwner() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        let c = await h.mcp(chat: h.key)
        c.receive(call(1, args: .object(["x": .number(1)])))
        #expect(await eventually { response(c, id: 1)?.0 == .object(["x": .number(1)]) })
        // the owner for the rest of the turn
        let a = await h.mcp()
        a.receive(call(2))
        #expect(await eventually { response(a, id: 2)?.1?.code == "busy" })
        c.receive(call(3))
        #expect(await eventually { response(c, id: 3) != nil })
    }

    @Test func wrongChatKeyIsTerminalClient() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        let c = await h.mcp(chat: "wrong")
        c.receive(call(1))
        #expect(await eventually { response(c, id: 1)?.1?.code == "busy" })
    }

    @Test func secondChatSendIsRejectedWithMessage() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        e.receive(.event(name: "chat.send", data: .object(["text": .string("again")])))
        #expect(await eventually { hasEvent(e, "chat.error", .object(["text": .string("Claude ещё отвечает")])) })
        #expect(h.processes[0].written.count == 1)
    }

    @Test func turnEndReleasesReservation() async {
        let h = DaemonChatHarness(lockIdle: 0.3)
        let e = await h.ext()
        await h.startTurn(e)
        h.endTurn()
        #expect(await eventually { hasEvent(e, "chat.turnEnd") })
        let a = await h.mcp()
        a.receive(call(1))
        #expect(await eventually { response(a, id: 1)?.0 == empty })

        // a chat owner keeps the lock for the whole turn, past lockIdle
        a.disconnect()
        #expect(await eventually { idles(e) == 2 }) // turn end without owner, then a's disconnect
        await h.startTurn(e)
        let c = await h.mcp(chat: h.key)
        c.receive(call(2))
        #expect(await eventually { response(c, id: 2) != nil })
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(idles(e) == 2)
        h.endTurn()
        #expect(await eventually { idles(e) == 3 })
        let b = await h.mcp()
        b.receive(call(3))
        #expect(await eventually { response(b, id: 3)?.0 == empty })
    }

    @Test func chatTurnEndReleasesLockAndSendsIdle() async {
        let h = DaemonChatHarness() // lockIdle 120 s: the release must not wait for it
        let e = await h.ext()
        await h.startTurn(e)
        let c = await h.mcp(chat: h.key)
        c.receive(call(1))
        #expect(await eventually { response(c, id: 1) != nil })
        h.endTurn()
        #expect(await eventually { idles(e) == 1 })
        let a = await h.mcp()
        a.receive(call(2))
        #expect(await eventually { response(a, id: 2)?.0 == empty })
    }

    @Test func chatTurnEndAfterStopReleasesLock() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        let c = await h.mcp(chat: h.key)
        c.receive(call(1))
        #expect(await eventually { response(c, id: 1) != nil })
        e.receive(.event(name: "stop", data: empty))
        #expect(await eventually { h.processes[0].written.count == 2 })
        c.receive(call(2))
        #expect(await eventually { response(c, id: 2)?.1?.code == "cancelled" })
        // claude ends the interrupted turn
        h.processes[0].onLine?(#"{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1,"session_id":"sess-1"}"#)
        #expect(await eventually { idles(e) == 1 })
        // Stop is cleared with the lock
        let a = await h.mcp()
        a.receive(call(3))
        #expect(await eventually { response(a, id: 3)?.0 == empty })
    }

    @Test func chatTurnEndDoesNotReleaseTerminalLock() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        let a = await h.mcp(), b = await h.mcp()
        a.receive(call(1))
        #expect(await eventually { response(a, id: 1) != nil })
        h.emit(.turnEnd)
        #expect(await eventually { hasEvent(e, "chat.turnEnd") })
        #expect(idles(e) == 0)
        b.receive(call(2))
        #expect(await eventually { response(b, id: 2)?.1?.code == "busy" })
    }

    @Test func chatEventsAreForwarded() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        h.processes[0].onLine?(#"{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"Hi"}}}"#)
        h.processes[0].onLine?(#"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"t1","name":"mcp__safari__ping","input":{"a":1}}]}}"#)
        #expect(await eventually { hasEvent(e, "chat.delta", .object(["text": .string("Hi")])) })
        #expect(await eventually { hasEvent(e, "chat.action", .object(["tool": .string("mcp__safari__ping"), "input": .object(["a": .number(1)])])) })
    }

    @Test func stopInterruptsChatTurnWithoutToolCall() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        e.receive(.event(name: "stop", data: empty))
        #expect(await eventually { h.processes[0].written.count == 2 })
        #expect(h.processes[0].written.last?.contains("interrupt") == true)
    }

    @Test func chatConfirmAllowRunsTool() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        let c = await h.mcp(chat: h.key)
        let args: JSON = .object(["kind": .string("click"), "ref": .string("e1")])
        c.receive(call(1, "confirm_action", args: args))
        #expect(await eventually { request(e, "chat.confirm") != nil })
        let r = request(e, "chat.confirm")!
        #expect(r.params == args)
        #expect(h.toolCalls.isEmpty)
        e.receive(.res(id: r.id, result: .object(["decision": .string("allow")]), error: nil))
        #expect(await eventually { response(c, id: 1)?.0 == args })
        #expect(h.toolCalls == ["confirm_action"])
    }

    @Test func chatConfirmDenyCancels() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        let c = await h.mcp(chat: h.key)
        for (id, decision) in [(1, "deny"), (2, "no")] {
            c.receive(call(id, "confirm_action", args: .object(["kind": .string("key"), "combo": .string("cmd+w")])))
            #expect(await eventually { e.sent.filter { if case .req(_, "chat.confirm", _) = $0 { return true }; return false }.count == id })
            let rid = e.sent.compactMap { m -> Int? in if case .req(let i, "chat.confirm", _) = m { return i }; return nil }.last!
            e.receive(.res(id: rid, result: .object(["decision": .string(decision)]), error: nil))
            #expect(await eventually { response(c, id: id)?.1 == .cancelled("Пользователь отказал") })
        }
        #expect(h.toolCalls.isEmpty)
    }

    @Test func chatConfirmStopCancels() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        let c = await h.mcp(chat: h.key)
        c.receive(call(1, "confirm_action", args: .object(["kind": .string("click"), "ref": .string("e1")])))
        #expect(await eventually { request(e, "chat.confirm") != nil })
        e.receive(.event(name: "stop", data: empty))
        #expect(await eventually { response(c, id: 1)?.1 == .cancelled("Пользователь отказал") })
        #expect(h.toolCalls.isEmpty)
    }

    @Test func chatConfirmPendingKeepsLockUntilAnswered() async {
        let h = DaemonChatHarness(lockIdle: 0.2)
        let e = await h.ext()
        await h.startTurn(e)
        let c = await h.mcp(chat: h.key)
        c.receive(call(1, "confirm_action", args: .object(["kind": .string("click"), "ref": .string("e1")])))
        #expect(await eventually { request(e, "chat.confirm") != nil })
        h.endTurn()
        #expect(await eventually { hasEvent(e, "chat.turnEnd") })
        try? await Task.sleep(nanoseconds: 500_000_000)
        #expect(!hasEvent(e, "idle"))
        let a = await h.mcp()
        a.receive(call(2))
        #expect(await eventually { response(a, id: 2)?.1?.code == "busy" })
        e.receive(.res(id: request(e, "chat.confirm")!.id, result: .object(["decision": .string("allow")]), error: nil))
        #expect(await eventually { response(c, id: 1)?.0 != nil })
        #expect(await eventually { hasEvent(e, "idle") })
    }

    @Test func chatConfirmExtensionGoneCancels() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        let c = await h.mcp(chat: h.key)
        c.receive(call(1, "confirm_action", args: .object(["kind": .string("click"), "ref": .string("e1")])))
        #expect(await eventually { request(e, "chat.confirm") != nil })
        e.disconnect()
        #expect(await eventually { response(c, id: 1)?.1 == .cancelled("Пользователь отказал") })
        #expect(h.toolCalls.isEmpty)
    }

    @Test func siteOnceUsesAllowOnce() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        let c = await h.mcp(chat: h.key)
        let args: JSON = .object(["kind": .string("site"), "domain": .string("a.com")])
        c.receive(call(1, "confirm_action", args: args))
        #expect(await eventually { request(e, "chat.confirm") != nil })
        e.receive(.res(id: request(e, "chat.confirm")!.id, result: .object(["decision": .string("once")]), error: nil))
        #expect(await eventually { request(e, "site.allowOnce") != nil })
        let once = request(e, "site.allowOnce")!
        #expect(once.params == .object(["domain": .string("a.com")]))
        e.receive(.res(id: once.id, result: .object([:]), error: nil))
        #expect(await eventually { response(c, id: 1)?.0 != nil })
        #expect(response(c, id: 1)?.1 == nil)
        #expect(h.toolCalls.isEmpty)

        // "always" persists through the tool as today
        c.receive(call(2, "confirm_action", args: args))
        #expect(await eventually { e.sent.filter { if case .req(_, "chat.confirm", _) = $0 { return true }; return false }.count == 2 })
        let rid = e.sent.compactMap { m -> Int? in if case .req(let i, "chat.confirm", _) = m { return i }; return nil }.last!
        e.receive(.res(id: rid, result: .object(["decision": .string("always")]), error: nil))
        #expect(await eventually { response(c, id: 2)?.0 == args })
        #expect(h.toolCalls == ["confirm_action"])
    }

    @Test func turnEndClearsOnceSites() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        h.endTurn()
        #expect(await eventually { request(e, "site.clearOnce") != nil })
        #expect(request(e, "site.clearOnce")?.params == empty)
    }

    @Test func terminalConfirmUnchanged() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        let a = await h.mcp()
        let args: JSON = .object(["kind": .string("click"), "ref": .string("e1")])
        a.receive(call(1, "confirm_action", args: args))
        #expect(await eventually { response(a, id: 1)?.0 == args })
        #expect(request(e, "chat.confirm") == nil)
    }

    @Test func askPageBusyWhenTerminalOwns() async {
        let h = DaemonChatHarness()
        let e = await h.ext(), a = await h.mcp()
        a.receive(call(1))
        #expect(await eventually { response(a, id: 1) != nil })
        e.receive(.event(name: "chat.askPage", data: .object(["tabId": .number(5)])))
        #expect(await eventually { hasEvent(e, "chat.busy") })
        #expect(request(e, "tabs.select") == nil)
    }

    @Test func askPageSelectsTab() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        e.receive(.event(name: "chat.askPage", data: .object(["tabId": .number(5)])))
        #expect(await eventually { request(e, "tabs.select") != nil })
        #expect(request(e, "tabs.select")?.params == .object(["tabId": .number(5)]))
        #expect(!hasEvent(e, "chat.busy"))
    }

    @Test func daemonStaysUpWhileClaudeRuns() async throws {
        let fired = Box()
        let h = DaemonChatHarness(idleExit: 0.2, exit: { fired.set() })
        let e = await h.ext()
        await h.startTurn(e)
        e.disconnect()
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(!fired.value)
        h.processes[0].onExit?(0)
        #expect(await eventually { fired.value })
    }

    @Test func chatNewResetsSession() async {
        let h = DaemonChatHarness()
        let e = await h.ext()
        await h.startTurn(e)
        e.receive(.event(name: "chat.new", data: empty))
        #expect(await eventually { h.processes[0].terminated })
        #expect(await eventually { hasEvent(e, "chat.turnEnd") })
        // a new turn starts a fresh claude
        await h.startTurn(e)
        #expect(h.processes.count == 2)
    }
}
