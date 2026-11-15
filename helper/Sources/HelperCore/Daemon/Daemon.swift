import ApplicationServices
import Foundation

/// Transport + routing + busy lock + lifecycle. Tool logic lives behind `ToolHandling`.
/// All mutable state is confined to `q`. Lives for the whole process, so closures capture it strongly.
public final class Daemon {
    private final class Client {
        let conn: Connection
        var role: Role?
        var helloTimer: DispatchWorkItem?
        init(_ c: Connection) { conn = c }
    }
    private final class Call {
        let id: Int
        var task: Task<Void, Never>?
        var responded = false
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

    public init(auth: Auth, tools: ToolHandling, idleExit: TimeInterval = 600, lockIdle: TimeInterval = 120,
                axTrusted: @escaping () -> Bool = { AXIsProcessTrusted() },
                exit: @escaping () -> Void = { Foundation.exit(0) }) {
        self.auth = auth
        self.axTrusted = axTrusted
        self.tools = tools
        self.link = ExtensionLink()
        exitMonitor = IdleMonitor(queue: q, delay: idleExit) { [self] in
            guard clients.isEmpty else { return }
            exit()
        }
        lockMonitor = IdleMonitor(queue: q, delay: lockIdle) { [self] in
            guard owner != nil, inflight.isEmpty else { return }
            releaseLock()
        }
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

    private func handle(_ client: Client, _ text: String) {
        guard clients[ObjectIdentifier(client.conn)] != nil else { return }
        guard let role = client.role else { handleHello(client, text); return }
        guard let msg = decode(text) else { return }
        switch (role, msg) {
        case (.extension_, .res(let id, let result, let error)):
            link.handleResponse(id: id, result: result, error: error)
        case (.extension_, .event(let name, _)):
            // Only the current extension connection may stop; a replaced one is ignored.
            if name == "stop", client === ext { handleStop() }
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
        guard let hello = decode(text), case .hello(let role, _, _) = hello,
              auth.authorize(hello: hello, origin: client.conn.origin) else {
            client.conn.close(code: 4001)
            return
        }
        client.role = role
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
        if let o = owner, o !== client {
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
        call.task = Task { [tools, link] in
            let result: Result<JSON, Error>
            do { result = .success(try await tools.call(name: name, arguments: args, link: link)) }
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
    }

    private func handleStop() {
        guard let o = owner else { return }
        stopped = true
        for (key, call) in inflight {
            call.responded = true
            call.task?.cancel()
            send(o.conn, .res(id: call.id, result: nil, error: .cancelled(Self.stopMessage)))
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
