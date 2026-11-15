import Testing
@testable import HelperCore

@Suite struct WSHandshakeTests {
    @Test func handshakeAcceptKey() throws {
        let req = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nOrigin: safari-web-extension://abc\r\n\r\n"
        let r = try #require(WSHandshake.response(forRequest: req))
        #expect(r.response.hasPrefix("HTTP/1.1 101"))
        #expect(r.response.contains("Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo="))
        #expect(r.origin == "safari-web-extension://abc")
    }

    @Test func nonWebSocketReturnsNil() {
        #expect(WSHandshake.response(forRequest: "GET / HTTP/1.1\r\nHost: x\r\n\r\n") == nil)
    }
}
