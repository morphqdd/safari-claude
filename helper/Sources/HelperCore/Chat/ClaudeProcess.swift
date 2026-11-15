import Foundation

/// A `claude` process. The launcher only prepares it; `start()` runs it once `onLine`/`onExit` are set,
/// so nothing it prints (or its exit) can be missed. Callbacks may arrive on any thread; `ChatSession` hops to its queue.
public protocol ClaudeProcess: AnyObject {
    var onLine: ((String) -> Void)? { get set }
    var onExit: ((Int32) -> Void)? { get set }
    /// Last bytes of stderr, for the error shown when the process dies mid-turn.
    var stderrTail: String { get }
    func start() throws
    func write(_ line: String)
    func terminate()
}

/// `arguments[0]` is the executable's absolute path.
public typealias ClaudeLauncher = (_ arguments: [String], _ environment: [String: String], _ cwd: URL) throws -> ClaudeProcess

public final class RealClaudeProcess: ClaudeProcess {
    public var onLine: ((String) -> Void)?
    public var onExit: ((Int32) -> Void)?

    private let process = Process()
    private let stdin = Pipe()
    private let stdout = Pipe()
    private let stderr = Pipe()
    /// Serializes output handling so every stdout line is delivered before `onExit`.
    private let io = DispatchQueue(label: "claude-io")
    private var buffer = Data()
    private var errTail = Data()
    /// Set on `io` by the exit drain; later readability callbacks read nothing.
    private var finished = false
    private static let tailLimit = 4096

    public static let launcher: ClaudeLauncher = { args, env, cwd in
        try RealClaudeProcess(arguments: args, environment: env, cwd: cwd)
    }

    public init(arguments: [String], environment: [String: String], cwd: URL) throws {
        guard let exe = arguments.first else { throw CocoaError(.fileNoSuchFile) }
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = Array(arguments.dropFirst())
        process.environment = environment
        process.currentDirectoryURL = cwd
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr
        // Writing after claude died must fail with EPIPE, not kill the daemon.
        _ = fcntl(stdin.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

        // Reads go through `poll`+`read` on `io`: FileHandle's availableData raises (and aborts the daemon)
        // on a read error, and reading on `io` keeps the order of chunks against the final drain at exit.
        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.io.sync { self?.pump(h, into: { $0.consume($1) }) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            self?.io.sync { self?.pump(h, into: { $0.appendErr($1) }) }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            self?.io.async {
                guard let self else { return }
                self.finished = true
                self.stdout.fileHandleForReading.readabilityHandler = nil
                self.stderr.fileHandleForReading.readabilityHandler = nil
                // What the pipes hold now, without waiting for EOF (an MCP child may still hold them open).
                self.appendErr(Self.readAvailable(self.stderr.fileHandleForReading.fileDescriptor).data)
                self.consume(Self.readAvailable(self.stdout.fileHandleForReading.fileDescriptor).data)
                if !self.buffer.isEmpty { self.deliver(self.buffer); self.buffer.removeAll() }
                self.onExit?(status)
            }
        }
    }

    public func start() throws {
        do { try process.run() } catch {
            // The handlers retain their handles; without this the six pipe fds would never be closed.
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            for h in [stdin.fileHandleForReading, stdin.fileHandleForWriting, stdout.fileHandleForReading,
                      stdout.fileHandleForWriting, stderr.fileHandleForReading, stderr.fileHandleForWriting] {
                try? h.close()
            }
            throw error
        }
    }

    public var stderrTail: String { io.sync { String(decoding: errTail, as: UTF8.self) } }

    public func write(_ line: String) {
        try? stdin.fileHandleForWriting.write(contentsOf: Data((line + "\n").utf8))
    }

    public func terminate() {
        try? stdin.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            deliver(line)
        }
    }

    private func deliver(_ line: Data) {
        if !line.isEmpty { onLine?(String(decoding: line, as: UTF8.self)) }
    }

    /// On `io`: reads what `h` holds and stops the handler at EOF. Nothing after the exit drain.
    private func pump(_ h: FileHandle, into sink: (RealClaudeProcess, Data) -> Void) {
        guard !finished else { h.readabilityHandler = nil; return }
        let (data, eof) = Self.readAvailable(h.fileDescriptor)
        if !data.isEmpty { sink(self, data) }
        if eof { h.readabilityHandler = nil }
    }

    /// Everything readable on `fd` right now, without blocking and without touching its flags;
    /// `eof` is true once the write end is closed (or the fd is unusable).
    static func readAvailable(_ fd: Int32) -> (data: Data, eof: Bool) {
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let r = poll(&pfd, 1, 0)
            if r < 0 && errno == EINTR { continue }
            if r <= 0 { return (out, false) }
            if pfd.revents & Int16(POLLIN | POLLHUP) == 0 { return (out, true) }
            let n = read(fd, &buf, buf.count)
            if n > 0 { out.append(contentsOf: buf[0..<n]); continue }
            if n < 0 && errno == EINTR { continue }
            return (out, true)
        }
    }

    private func appendErr(_ data: Data) {
        errTail.append(data)
        if errTail.count > Self.tailLimit { errTail = errTail.suffix(Self.tailLimit) }
    }
}
