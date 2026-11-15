import Foundation

struct WSFrameError: Error, Equatable {
    /// WebSocket close code to send before dropping the connection.
    let closeCode: UInt16
    static let protocolError = WSFrameError(closeCode: 1002)
    static let tooLarge = WSFrameError(closeCode: 1009)
}

struct WSFrame: Equatable {
    static let maxPayload = 16 * 1024 * 1024

    var fin: Bool
    var opcode: UInt8
    var payload: [UInt8]

    /// Consumes one client frame from `buf`. Returns nil (buffer untouched) if incomplete.
    /// Client frames must be masked; payloads are returned unmasked.
    static func parse(_ buf: inout [UInt8]) throws -> WSFrame? {
        guard buf.count >= 2 else { return nil }
        let b0 = buf[0], b1 = buf[1]
        if b0 & 0x70 != 0 { throw WSFrameError.protocolError }
        guard b1 & 0x80 != 0 else { throw WSFrameError.protocolError }
        var len = Int(b1 & 0x7F)
        var idx = 2
        if len == 126 {
            guard buf.count >= 4 else { return nil }
            len = Int(buf[2]) << 8 | Int(buf[3])
            idx = 4
        } else if len == 127 {
            guard buf.count >= 10 else { return nil }
            var n: UInt64 = 0
            for i in 2..<10 { n = n << 8 | UInt64(buf[i]) }
            if n > UInt64(maxPayload) { throw WSFrameError.tooLarge }
            len = Int(n)
            idx = 10
        }
        if len > maxPayload { throw WSFrameError.tooLarge }
        let opcode = b0 & 0x0F
        if opcode & 0x8 != 0 && (len > 125 || b0 & 0x80 == 0) { throw WSFrameError.protocolError }
        guard buf.count >= idx + 4 + len else { return nil }
        let mask = Array(buf[idx..<idx + 4])
        idx += 4
        var payload = Array(buf[idx..<idx + len])
        for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
        buf.removeFirst(idx + len)
        return WSFrame(fin: b0 & 0x80 != 0, opcode: opcode, payload: payload)
    }

    /// Unmasked server frame.
    func encode() -> [UInt8] {
        var out: [UInt8] = [(fin ? 0x80 : 0) | (opcode & 0x0F)]
        let n = payload.count
        if n < 126 {
            out.append(UInt8(n))
        } else if n <= 0xFFFF {
            out += [126, UInt8(n >> 8), UInt8(n & 0xFF)]
        } else {
            out.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8((UInt64(n) >> UInt64(shift)) & 0xFF)) }
        }
        return out + payload
    }
}
