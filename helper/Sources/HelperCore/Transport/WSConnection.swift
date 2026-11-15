import Foundation

/// One accepted socket. Performs the HTTP upgrade, then speaks WebSocket. All state lives on `queue`.
final class WSConnection {
    private(set) var origin: String?
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?

    private let fd: Int32
    private let queue: DispatchQueue
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var writeSourceActive = false
    private var inbuf: [UInt8] = []
    private var outbuf: [UInt8] = []
    private var upgraded = false
    private var closing = false   // close frame sent; finish once flushed
    private var finished = false
    private var fragments: [UInt8]?
    private let onUpgrade: (WSConnection) -> Void

    init(fd: Int32, queue: DispatchQueue, onUpgrade: @escaping (WSConnection) -> Void) {
        self.fd = fd
        self.queue = queue
        self.onUpgrade = onUpgrade
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    func start() {
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [self] in readable() }
        rs.resume()
        readSource = rs
    }

    // MARK: Public API (thread-safe)

    func send(_ text: String) {
        queue.async { [self] in
            guard upgraded, !closing, !finished else { return }
            write(WSFrame(fin: true, opcode: 1, payload: Array(text.utf8)).encode())
        }
    }

    func close(code: UInt16) {
        queue.async { [self] in sendClose(code) }
    }

    func ping() {
        queue.async { [self] in
            guard upgraded, !closing, !finished else { return }
            write(WSFrame(fin: true, opcode: 9, payload: []).encode())
        }
    }

    // MARK: Reading

    private func readable() {
        var tmp = [UInt8](repeating: 0, count: 65536)
        while !finished {
            let n = read(fd, &tmp, tmp.count)
            if n > 0 {
                inbuf += tmp[0..<n]
                process()
            } else if n == 0 {
                finish()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                finish()
                return
            }
        }
    }

    private func process() {
        if !upgraded {
            guard let end = findHeaderEnd() else {
                if inbuf.count > 16384 { rejectHTTP() }
                return
            }
            let raw = String(decoding: inbuf[0..<end], as: UTF8.self)
            guard let hs = WSHandshake.response(forRequest: raw) else { rejectHTTP(); return }
            inbuf.removeFirst(end)
            origin = hs.origin
            upgraded = true
            write(Array(hs.response.utf8))
            onUpgrade(self)
        }
        while upgraded, !finished, !closing {
            do {
                guard let frame = try WSFrame.parse(&inbuf) else { return }
                handle(frame)
            } catch let e as WSFrameError {
                sendClose(e.closeCode)
                return
            } catch {
                sendClose(1002)
                return
            }
        }
    }

    private func findHeaderEnd() -> Int? {
        let pat: [UInt8] = [13, 10, 13, 10]
        guard inbuf.count >= 4 else { return nil }
        for i in 0...(inbuf.count - 4) where inbuf[i] == 13 && Array(inbuf[i..<i + 4]) == pat { return i + 4 }
        return nil
    }

    private func rejectHTTP() {
        write(Array("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8))
        closing = true
        flushThenFinish()
    }

    private func handle(_ f: WSFrame) {
        switch f.opcode {
        case 0x1, 0x0:
            if f.opcode == 0x1 {
                if fragments != nil { sendClose(1002); return }
                fragments = f.payload
            } else {
                guard fragments != nil else { sendClose(1002); return }
                fragments! += f.payload
                if fragments!.count > WSFrame.maxPayload { sendClose(1009); return }
            }
            if f.fin {
                let data = fragments!
                fragments = nil
                guard let text = String(data: Data(data), encoding: .utf8) else { sendClose(1007); return }
                onText?(text)
            }
        case 0x2:
            sendClose(1003)
        case 0x8:
            let code = f.payload.count >= 2 ? UInt16(f.payload[0]) << 8 | UInt16(f.payload[1]) : 1005
            sendClose(code == 1005 ? 1000 : code)
        case 0x9:
            write(WSFrame(fin: true, opcode: 0xA, payload: f.payload).encode())
        case 0xA:
            break
        default:
            sendClose(1002)
        }
    }

    // MARK: Writing

    private func sendClose(_ code: UInt16) {
        guard !closing, !finished else { return }
        closing = true
        if upgraded {
            write(WSFrame(fin: true, opcode: 8, payload: [UInt8(code >> 8), UInt8(code & 0xFF)]).encode())
        }
        flushThenFinish()
    }

    private func write(_ bytes: [UInt8]) {
        outbuf += bytes
        flush()
    }

    private func flush() {
        while !outbuf.isEmpty && !finished {
            let n = outbuf.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if n > 0 {
                outbuf.removeFirst(n)
            } else if n < 0 && errno == EINTR {
                continue
            } else if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                armWriteSource()
                return
            } else {
                finish()
                return
            }
        }
        if outbuf.isEmpty {
            disarmWriteSource()
            if closing { finish() }
        }
    }

    private func flushThenFinish() {
        if outbuf.isEmpty { finish() } else { flush() }
    }

    private func armWriteSource() {
        if writeSource == nil {
            let ws = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
            ws.setEventHandler { [self] in flush() }
            writeSource = ws
        }
        if !writeSourceActive { writeSourceActive = true; writeSource?.resume() }
    }

    private func disarmWriteSource() {
        if writeSourceActive { writeSourceActive = false; writeSource?.suspend() }
    }

    // MARK: Teardown

    private func finish() {
        guard !finished else { return }
        finished = true
        let fd = self.fd
        if let ws = writeSource {
            if !writeSourceActive { ws.resume() }   // cancel requires a resumed source
            ws.cancel()
        }
        writeSource = nil
        readSource?.setCancelHandler { Darwin.close(fd) }
        readSource?.cancel()
        readSource = nil
        let cb = upgraded ? onClose : nil
        onClose = nil
        onText = nil
        cb?()
    }
}
