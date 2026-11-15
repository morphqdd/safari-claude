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

        stdout.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.io.async { self?.consume(data) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [weak self] h in
            let data = h.availableData
            if data.isEmpty { h.readabilityHandler = nil; return }
            self?.io.async { self?.appendErr(data) }
        }
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            self?.io.async {
                guard let self else { return }
                self.stdout.fileHandleForReading.readabilityHandler = nil
                self.stderr.fileHandleForReading.readabilityHandler = nil
                self.appendErr(Self.drain(self.stderr.fileHandleForReading.fileDescriptor))
                self.consume(self.stdout.fileHandleForReading.readDataToEndOfFile())
                if !self.buffer.isEmpty { self.deliver(self.buffer); self.buffer.removeAll() }
                self.onExit?(status)
            }
        }
    }

    public func start() throws { try process.run() }

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

    /// What stderr holds right now, without waiting for EOF (an MCP child may still hold the pipe open).
    private static func drain(_ fd: Int32) -> Data {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var out = Data()
        var buf = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(fd, &buf, buf.count)
            if n <= 0 { break }
            out.append(contentsOf: buf[0..<n])
        }
        return out
    }

    private func appendErr(_ data: Data) {
        errTail.append(data)
        if errTail.count > Self.tailLimit { errTail = errTail.suffix(Self.tailLimit) }
    }
}
