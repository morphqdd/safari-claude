import ApplicationServices
import Foundation

/// Transport + routing + busy lock + lifecycle. Tool logic lives behind `ToolHandling`.
/// All mutable state is confined to `q`. Lives for the whole process, so closures capture it strongly.
public final class Daemon {
    private final class Client {
        let conn: Connection
        var role: Role?
        /// MCP process started by the chat's claude (its hello carried the current chat key).
        var isChat = false
        var helloTimer: DispatchWorkItem?
        init(_ c: Connection) { conn = c }
    }
    private final class Call {
        let id: Int
        var task: Task<Void, Never>?
        var responded = false
        /// A chat confirm_action whose card is still waiting for the owner.
        var confirming = false
        init(id: Int) { self.id = id }
    }

    public let link: ExtensionLink
    private let auth: Auth
    private let tools: ToolHandling
    private let q = DispatchQueue(label: "safari-claude.daemon")
    private var exitMonitor: IdleMonitor!
    private var lockMonitor: IdleMonitor!
    private var clients: [ObjectIdentifier: Client] = [:]
    private var ext: Client?
    private var owner: Client?
    /// Set by Stop; every tool.call from the owner is cancelled until the lock is released
    /// (lockIdle expiry or owner disconnect).
    private var stopped = false
    static let stopMessage = "Пользователь нажал «Стоп». Не повторяй действие — спроси пользователя, что делать дальше."
    private var inflight: [ObjectIdentifier: Call] = [:]
    private let axTrusted: () -> Bool
    private var chat: ChatSession?
    /// From chat.send to turnEnd the lock is held for the chat, even before its claude calls a tool.
    private var chatReserved = false
    static let deniedMessage = "Пользователь отказал"

    /// `chat` builds the chat window's session on the daemon queue, with the daemon's event handler.
    public init(auth: Auth, tools: ToolHandling, idleExit: TimeInterval = 600, lockIdle: TimeInterval = 120,
                chat: ((DispatchQueue, @escaping (ChatEvent) -> Void) -> ChatSession)? = nil,
                axTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
                exit: @escaping () -> Void = { Foundation.exit(0) }) {
        self.auth = auth
        self.axTrusted = axTrusted
        self.tools = tools
        self.link = ExtensionLink()
        exitMonitor = IdleMonitor(queue: q, delay: idleExit) { [self] in
            guard clients.isEmpty else { return }
            // claude may be between turns with its MCP process not connected; check again later.
            if self.chat?.isRunning == true { exitMonitor.arm(); return }
            exit()
        }
        lockMonitor = IdleMonitor(queue: q, delay: lockIdle) { [self] in
            guard owner != nil, inflight.isEmpty, !chatReserved else { return }
            releaseLock()
        }
        self.chat = chat?(q) { [self] event in chatEvent(event) }
        q.async { self.exitMonitor.arm() }
    }

    /// Binds a listener (launchd socket, or 127.0.0.1:devPort) and routes accepted connections here.
    public func serve(devPort: UInt16?) throws {
        let listener = try devPort.map { try Listener.tcp(port: $0) } ?? Listener.launchd(name: "Listener")
        listener.onConnection = { [self] c in accept(c) }
        let lq = DispatchQueue(label: "safari-claude.listener")
        listener.start(queue: lq)
        keepAlive = listener
    }
    private var keepAlive: AnyObject?

    func accept(_ c: Connection) {
        // Callbacks are installed synchronously so no frame arriving right after upgrade is lost;
        // handling then hops to `q`, which orders it after the registration below.
        let client = Client(c)
        c.onText = { [self] text in q.async { handle(client, text) } }
        c.onClose = { [self] in q.async { disconnected(client) } }
        q.async { [self] in
            let key = ObjectIdentifier(c)
            clients[key] = client
            exitMonitor.disarm()
            let timer = DispatchWorkItem {
                guard client.role == nil else { return }
                c.close(code: 4001)
            }
            client.helloTimer = timer
            q.asyncAfter(deadline: .now() + 5, execute: timer)
        }
    }

    // MARK: Incoming

    private func decode(_ text: String) -> Message? {
        try? JSONDecoder().decode(Message.self, from: Data(text.utf8))
    }

    private func send(_ c: Connection, _ m: Message) {
        if let d = try? JSONEncoder().encode(m), let s = String(data: d, encoding: .utf8) { c.send(s) }
    }

    private func sendExt(_ name: String, _ data: [String: JSON] = [:]) {
        if let e = ext { send(e.conn, .event(name: name, data: .object(data))) }
    }

    private func handle(_ client: Client, _ text: String) {
        guard clients[ObjectIdentifier(client.conn)] != nil else { return }
        guard let role = client.role else { handleHello(client, text); return }
        guard let msg = decode(text) else { return }
        switch (role, msg) {
        case (.extension_, .res(let id, let result, let error)):
            link.handleResponse(id: id, result: result, error: error)
        case (.extension_, .event(let name, let data)):
            // Only the current extension connection is listened to; a replaced one is ignored.
            guard client === ext else { return }
            switch name {
            case "stop": handleStop()
            case "chat.send": chatSend(data["text"]?.string ?? "")
            case "chat.new":
                chat?.interrupt()
                chat?.reset()
            case "chat.askPage": askPage(data["tabId"])
            default: break
            }
        case (.extension_, .req(let id, _, _)):
            send(client.conn, .res(id: id, result: nil, error: .badRequest("extension cannot send requests")))
        case (.mcp, .req(let id, let method, let params)):
            if method == "status" {
                send(client.conn, .res(id: id, result: .object(["extensionConnected": .bool(ext != nil), "axTrusted": .bool(axTrusted())]), error: nil))
                return
            }
            guard method == "tool.call" else {
                send(client.conn, .res(id: id, result: nil, error: .badRequest("unknown method \(method)")))
                return
            }
            handleToolCall(client, id: id, params: params)
        default:
            break
        }
    }

    private func handleHello(_ client: Client, _ text: String) {
        client.helloTimer?.cancel()
        guard let hello = decode(text), case .hello(let role, _, let chatKey) = hello,
              auth.authorize(hello: hello, origin: client.conn.origin) else {
            client.conn.close(code: 4001)
            return
        }
        client.role = role
        client.isChat = role == .mcp && chatKey != nil && chatKey == chat?.chatKey
        if role == .extension_ {
            if let old = ext {
                old.conn.close(code: 4002)
                link.detach(old.conn)
            }
            ext = client
            link.attach(client.conn)
        }
        send(client.conn, .welcome)
    }

    // MARK: Tool calls and lock

    private func handleToolCall(_ client: Client, id: Int, params: JSON) {
        let blocked = chatReserved ? !client.isChat : owner.map { $0 !== client } ?? false
        if blocked {
            send(client.conn, .res(id: id, result: nil, error: .busy("Safari занят другой сессией Claude")))
            return
        }
        owner = client
        if stopped {
            // The lock idle timer keeps running from Stop; cancelled calls do not extend it.
            send(client.conn, .res(id: id, result: nil, error: .cancelled(Self.stopMessage)))
            return
        }
        guard let name = params["name"]?.string else {
            send(client.conn, .res(id: id, result: nil, error: .badRequest("missing tool name")))
            lockMonitor.arm()
            return
        }
        lockMonitor.disarm()
        let call = Call(id: id)
        let key = ObjectIdentifier(call)
        inflight[key] = call
        let args = params["arguments"] ?? .object([:])
        let confirm = name == "confirm_action" && client.isChat
        call.confirming = confirm
        call.task = Task { [tools, link] in
            let result: Result<JSON, Error>
            do {
                if confirm { result = .success(try await self.chatConfirm(call, args)) }
                else { result = .success(try await tools.call(name: name, arguments: args, link: link)) }
            }
            catch { result = .failure(error) }
            self.q.async { self.finish(call, client, result) }
        }
    }

    private func finish(_ call: Call, _ client: Client, _ result: Result<JSON, Error>) {
        guard inflight.removeValue(forKey: ObjectIdentifier(call)) != nil else { return }
        if !call.responded {
            call.responded = true
            switch result {
            case .success(let r): send(client.conn, .res(id: call.id, result: r, error: nil))
            case .failure(let e):
                let err = (e as? RPCError) ?? (e is CancellationError ? .cancelled() : .internal("\(e)"))
                send(client.conn, .res(id: call.id, result: nil, error: err))
            }
        }
        if owner === client && inflight.isEmpty { lockMonitor.arm() }
        // e.g. a confirm card answered after the turn ended
        if owner === client && client.isChat { releaseIfChatDone() }
    }

    /// Once the chat's turn is over and nothing is in flight, Safari is released right away
    /// (`idle` hides the page overlay and clears Stop); terminal owners keep the lockIdle behaviour.
    private func releaseIfChatDone() {
        guard !chatReserved, inflight.isEmpty, owner?.isChat ?? true else { return }
        releaseLock()
    }

    /// Asks the owner in the chat window; runs the tool only if allowed. Called off-queue from the call's task.
    private func chatConfirm(_ call: Call, _ args: JSON) async throws -> JSON {
        // No timeout: the card waits for the owner. Stop cancels the task; a gone extension fails the request.
        let decision = try? await link.request("chat.confirm", args, timeout: .infinity)["decision"]?.string
        q.sync { call.confirming = false }
        switch decision {
        case "once" where args["kind"]?.string == "site":
            guard let d = args["domain"]?.string else { throw RPCError.badRequest("missing argument: domain") }
            _ = try await link.request("site.allowOnce", .object(["domain": .string(d)]))
            return .object(["content": .array([.object(["type": .string("text"), "text": .string("allowed \(d) for this turn")])]),
                            "isError": .bool(false)])
        case "allow", "once", "always":
            return try await tools.call(name: "confirm_action", arguments: args, link: link)
        default:
            throw RPCError.cancelled(Self.deniedMessage)
        }
    }

    private func handleStop() {
        if chatReserved {
            stopped = true
            chat?.interrupt()
        }
        guard let o = owner else { return }
        stopped = true
        for (key, call) in inflight {
            call.responded = true
            call.task?.cancel()
            send(o.conn, .res(id: call.id, result: nil, error: .cancelled(call.confirming ? Self.deniedMessage : Self.stopMessage)))
            inflight.removeValue(forKey: key)
        }
        lockMonitor.arm()
    }

    private func releaseLock() {
        owner = nil
        stopped = false
        lockMonitor.disarm()
        if let e = ext { send(e.conn, .event(name: "idle", data: .object([:]))) }
    }

    // MARK: Chat window

    private func chatSend(_ text: String) {
        guard let chat else { return }
        if let o = owner, !o.isChat { sendExt("chat.busy"); return }
        let wasStopped = stopped
        stopped = false
        chatReserved = true
        lockMonitor.disarm()
        do { try chat.send(text) } catch {
            // The current turn goes on as it was.
            stopped = wasStopped
            sendExt("chat.error", ["text": .string((error as? RPCError)?.message ?? "\(error)")])
        }
    }

    private func chatEvent(_ event: ChatEvent) {
        switch event {
        case .delta(let text): sendExt("chat.delta", ["text": .string(text)])
        case .action(let tool, let input): sendExt("chat.action", ["tool": .string(tool), "input": input])
        case .notice(let text): sendExt("chat.notice", ["text": .string(text)])
        case .error(let text): sendExt("chat.error", ["text": .string(text)])
        case .turnEnd:
            sendExt("chat.turnEnd")
            chatReserved = false
            releaseIfChatDone()
            // Sites allowed "once" last for one turn. Best-effort.
            Task { [link] in _ = try? await link.request("site.clearOnce", .object([:])) }
        }
    }

    private func askPage(_ tabId: JSON?) {
        if let o = owner, !o.isChat { sendExt("chat.busy"); return }
        guard let tabId else { return }
        Task { [link] in _ = try? await link.request("tabs.select", .object(["tabId": tabId])) }
    }

    // MARK: Disconnect

    private func disconnected(_ client: Client) {
        client.helloTimer?.cancel()
        guard clients.removeValue(forKey: ObjectIdentifier(client.conn)) != nil else { return }
        if ext === client {
            ext = nil
            link.detach(client.conn)
        }
        if owner === client {
            for call in inflight.values { call.responded = true; call.task?.cancel() }
            inflight.removeAll()
            releaseLock()
        }
        if clients.isEmpty { exitMonitor.arm() }
    }
}
