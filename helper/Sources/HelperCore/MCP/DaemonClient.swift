import Foundation

/// WebSocket client to the helper daemon. Connects lazily (which wakes the daemon via launchd)
/// and reconnects on the next call after a failure. Calls are expected to be sequential.
public final class DaemonClient: @unchecked Sendable {
    private let port: UInt16
    private let token: String
    private let chatKey: String?
    private let timeout: TimeInterval
    private let session = URLSession(configuration: .ephemeral)
    private var task: URLSessionWebSocketTask?
    private var nextId = 1
    private let lock = NSLock()

    public init(port: UInt16 = 47821, token: String, timeout: TimeInterval = 120, chatKey: String? = nil) {
        self.port = port
        self.token = token
        self.chatKey = chatKey
        self.timeout = timeout
    }

    public func call(_ name: String, _ args: JSON) async throws -> JSON {
        try await request("tool.call", .object(["name": .string(name), "arguments": args]))
    }

    /// Asks the daemon whether the Safari extension is connected and whether the daemon itself
    /// (the process launchd runs, not the caller) has the Accessibility permission.
    public func daemonStatus() async throws -> (extensionConnected: Bool, axTrusted: Bool) {
        let r = try await request("status", .object([:]))
        return (r["extensionConnected"]?.bool ?? false, r["axTrusted"]?.bool ?? false)
    }

    private func request(_ method: String, _ params: JSON) async throws -> JSON {
        let id = lock.withLock { () -> Int in defer { nextId += 1 }; return nextId }
        let timedOut = lock.withLock { Flag() }
        do {
            return try await withTimeout(timedOut) { [self] in
                let ws = try await connectedTask()
                try await send(ws, .req(id: id, method: method, params: params))
                while true {
                    let m = try await receive(ws)
                    guard case .res(let rid, let result, let error) = m, rid == id else { continue }
                    if let error { throw error }
                    return result ?? .null
                }
            }
        } catch {
            if timedOut.value { throw RPCError.timeout("daemon did not reply within \(timeout)s") }
            if let e = error as? RPCError {
                // A reply from the daemon (or a local RPCError): the socket is still healthy.
                throw e
            }
            drop()
            throw RPCError.internal("helper daemon unavailable: \(error)")
        }
    }

    private final class Flag: @unchecked Sendable {
        private let l = NSLock()
        private var v = false
        var value: Bool { l.withLock { v } }
        func set() { l.withLock { v = true } }
    }

    private func connectedTask() async throws -> URLSessionWebSocketTask {
        let existing = lock.withLock { task }
        if let existing { return existing }
        let ws = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)")!)
        ws.maximumMessageSize = WSFrame.maxPayload // default 1 MiB rejects screenshots
        lock.withLock { task = ws }
        ws.resume()
        do {
            try await send(ws, .hello(role: .mcp, token: token, chat: chatKey))
            guard case .welcome = try await receive(ws) else {
                throw RPCError.internal("unexpected handshake reply")
            }
        } catch {
            drop()
            throw error
        }
        return ws
    }

    private func drop() {
        let t = lock.withLock { () -> URLSessionWebSocketTask? in defer { task = nil }; return task }
        t?.cancel(with: .goingAway, reason: nil)
    }

    private func send(_ ws: URLSessionWebSocketTask, _ m: Message) async throws {
        let data = try JSONEncoder().encode(m)
        try await ws.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func receive(_ ws: URLSessionWebSocketTask) async throws -> Message {
        switch try await ws.receive() {
        case .string(let s): return try JSONDecoder().decode(Message.self, from: Data(s.utf8))
        case .data(let d): return try JSONDecoder().decode(Message.self, from: d)
        @unknown default: throw RPCError.internal("unsupported frame")
        }
    }

    /// Races `op` against the timeout. On timeout the socket is dropped so a pending receive
    /// throws and the group can unwind; the next call reconnects.
    private func withTimeout<T: Sendable>(_ flag: Flag, _ op: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withTaskCancellationHandler {
          try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await op() }
            group.addTask { [timeout, self] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                flag.set()
                drop()
                throw RPCError.timeout("timeout")
            }
            defer { group.cancelAll() }
            return try await group.next()!
          }
        } onCancel: { [self] in drop() }
    }
}
