import Foundation

struct ListenerError: Error, CustomStringConvertible {
    let description: String
}

/// Accepts connections on a listening socket and hands upgraded WebSocket connections to `onConnection`.
final class Listener {
    var onConnection: ((WSConnection) -> Void)?
    private(set) var boundPort: UInt16 = 0
    private let fd: Int32
    private var source: DispatchSourceRead?

    private init(fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        if ok == 0 { boundPort = UInt16(bigEndian: addr.sin_port) }
    }

    /// Adopts the socket launchd opened for the named entry in the job's Sockets dictionary.
    static func launchd(name: String) throws -> Listener {
        // launch_activate_socket overwrites this with a malloc'd array on success.
        var fds = UnsafeMutablePointer<Int32>(bitPattern: MemoryLayout<Int32>.alignment)!
        var count = 0
        let rc = launch_activate_socket(name, &fds, &count)
        guard rc == 0, count > 0 else {
            let reason = rc == 0 ? "no sockets returned" : String(cString: strerror(rc))
            throw ListenerError(description: "launch_activate_socket(\"\(name)\") failed: \(reason) (code \(rc)); not running under launchd?")
        }
        let first = fds[0]
        for i in 1..<count { Darwin.close(fds[i]) }
        free(fds)
        return Listener(fd: first)
    }

    /// Development/test listener on 127.0.0.1. Port 0 picks an ephemeral port (see `boundPort`).
    static func tcp(port: UInt16) throws -> Listener {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ListenerError(description: "socket: \(String(cString: strerror(errno)))") }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F000001).bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            let msg = String(cString: strerror(errno))
            Darwin.close(fd)
            throw ListenerError(description: "bind/listen 127.0.0.1:\(port): \(msg)")
        }
        return Listener(fd: fd)
    }

    func start(queue: DispatchQueue) {
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll(queue: queue) }
        let fd = self.fd
        src.setCancelHandler { Darwin.close(fd) }
        src.resume()
        source = src
    }

    private func acceptAll(queue: DispatchQueue) {
        while true {
            let cfd = accept(fd, nil, nil)
            if cfd < 0 { return }
            let conn = WSConnection(fd: cfd, queue: queue) { [weak self] c in self?.onConnection?(c) }
            conn.start()
        }
    }
}
