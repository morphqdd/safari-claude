import Testing
import Foundation
@testable import HelperCore

@Test func helloRoundTrip() throws {
    let msg = Message.hello(role: .mcp, token: "t")
    let enc = JSONEncoder()
    enc.outputFormatting = [.sortedKeys]
    let data = try enc.encode(msg)
    #expect(String(decoding: data, as: UTF8.self) == #"{"role":"mcp","token":"t","type":"hello"}"#)
    #expect(try JSONDecoder().decode(Message.self, from: data) == msg)
    let ordered = Data(#"{"type":"hello","role":"mcp","token":"t"}"#.utf8)
    #expect(try JSONDecoder().decode(Message.self, from: ordered) == msg)
}

@Test func resWithErrorDecodes() throws {
    let data = Data(#"{"type":"res","id":3,"error":{"code":"busy","message":"x"}}"#.utf8)
    let msg = try JSONDecoder().decode(Message.self, from: data)
    #expect(msg == .res(id: 3, result: nil, error: RPCError(code: "busy", message: "x")))
}
