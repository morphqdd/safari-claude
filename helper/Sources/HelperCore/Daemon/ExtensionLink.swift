import Foundation

protocol Connection: AnyObject {
    var origin: String? { get }
    var onText: ((String) -> Void)? { get set }
    var onClose: (() -> Void)? { get set }
    func send(_ text: String)
    func close(code: UInt16)
}

extension WSConnection: Connection {}

public protocol ToolHandling {
    func call(name: String, arguments: JSON, link: ExtensionLink) async throws -> JSON
}

/// Request/response channel to the (single) Safari extension connection. Thread-safe.
public final class ExtensionLink {
    static let noExtensionMessage = "Safari не запущен или расширение «Safari Agent» выключено"

    private final class Pending {
        var id = 0
        var cont: CheckedContinuation<JSON, Error>?
        var timer: DispatchWorkItem?
        var done = false
    }
    private final class Waiter {
        let cont: CheckedContinuation<Void, Error>
        var timer: DispatchWorkItem?
        init(_ c: CheckedContinuation<Void, Error>) { cont = c }
    }

    private let lock = NSLock()
    private var conn: Connection?
    private var pending: [Int: Pending] = [:]
    private var waiters: [Int: Waiter] = [:]
    private var nextId = 1
    private var nextWaiter = 1
    private let connectWait: TimeInterval
    private let requestTimeout: TimeInterval

    init(connectWait: TimeInterval = 3, requestTimeout: TimeInterval = 15) {
        self.connectWait = connectWait
        self.requestTimeout = requestTimeout
    }

    public var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return conn != nil
    }

    /// `timeout` defaults to the link's request timeout (15 s).
    public func request(_ method: String, _ params: JSON, timeout: TimeInterval? = nil) async throws -> JSON {
        let timeout = timeout ?? requestTimeout
        try await waitForConnection()
        let p = Pending()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<JSON, Error>) in
                lock.lock()
                if p.done {
                    lock.unlock()
                    cont.resume(throwing: RPCError.cancelled())
                    return
                }
                guard let c = conn else {
                    lock.unlock()
                    cont.resume(throwing: RPCError.noExtension(Self.noExtensionMessage))
                    return
                }
                p.cont = cont
                p.id = nextId
                nextId += 1
                pending[p.id] = p
                let timer = DispatchWorkItem { [weak self] in self?.finish(p, .failure(RPCError.timeout())) }
                p.timer = timer
                let id = p.id
                lock.unlock()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)
                if let data = try? JSONEncoder().encode(Message.req(id: id, method: method, params: params)),
                   let text = String(data: data, encoding: .utf8) {
                    c.send(text)
                }
            }
        } onCancel: {
            self.finish(p, .failure(RPCError.cancelled()))
        }
    }

    private func waitForConnection() async throws {
        lock.lock()
        if conn != nil { lock.unlock(); return }
        lock.unlock()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if conn != nil { lock.unlock(); cont.resume(); return }
            let w = Waiter(cont)
            let key = nextWaiter
            nextWaiter += 1
            waiters[key] = w
            let timer = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let w = self.waiters.removeValue(forKey: key)
                self.lock.unlock()
                w?.cont.resume(throwing: RPCError.noExtension(Self.noExtensionMessage))
            }
            w.timer = timer
            lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + connectWait, execute: timer)
        }
    }

    private func finish(_ p: Pending, _ result: Result<JSON, Error>) {
        lock.lock()
        guard !p.done else { lock.unlock(); return }
        p.done = true
        if p.id != 0 { pending.removeValue(forKey: p.id) }
        p.timer?.cancel()
        let cont = p.cont
        p.cont = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    // MARK: Called by Daemon

    func attach(_ c: Connection) {
        lock.lock()
        let old = Array(pending.values)
        conn = c
        let ws = Array(waiters.values)
        waiters.removeAll()
        lock.unlock()
        for p in old { finish(p, .failure(RPCError.noExtension(Self.noExtensionMessage))) }
        for w in ws { w.timer?.cancel(); w.cont.resume() }
    }

    func detach(_ c: Connection) {
        lock.lock()
        guard conn === c else { lock.unlock(); return }
        conn = nil
        let old = Array(pending.values)
        lock.unlock()
        for p in old { finish(p, .failure(RPCError.noExtension(Self.noExtensionMessage))) }
    }

    func handleResponse(id: Int, result: JSON?, error: RPCError?) {
        lock.lock()
        let p = pending[id]
        lock.unlock()
        guard let p else { return }
        if let error { finish(p, .failure(error)) } else { finish(p, .success(result ?? .null)) }
    }
}
