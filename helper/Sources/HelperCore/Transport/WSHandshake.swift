import Foundation
import CryptoKit

enum WSHandshake {
    /// Builds the 101 response for a valid WebSocket upgrade request, or nil if the request is not one.
    static func response(forRequest raw: String) -> (response: String, origin: String?)? {
        var headers: [String: String] = [:]
        let lines = raw.components(separatedBy: "\r\n")
        guard let first = lines.first, first.hasPrefix("GET ") else { return nil }
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard headers["upgrade"]?.lowercased() == "websocket",
              headers["connection"]?.lowercased().contains("upgrade") == true,
              headers["sec-websocket-version"] == "13",
              let key = headers["sec-websocket-key"], !key.isEmpty else { return nil }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        return (resp, headers["origin"])
    }
}
