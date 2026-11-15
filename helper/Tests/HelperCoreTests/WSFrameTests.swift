import Testing
@testable import HelperCore

@Suite struct WSFrameTests {
    static let hello: [UInt8] = [0x81, 0x85, 0x37, 0xfa, 0x21, 0x3d, 0x7f, 0x9f, 0x4d, 0x51, 0x58]

    @Test func parsesMaskedClientText() throws {
        var buf = Self.hello
        let f = try #require(try WSFrame.parse(&buf))
        #expect(f.opcode == 1)
        #expect(f.fin)
        #expect(String(decoding: f.payload, as: UTF8.self) == "Hello")
        #expect(buf.isEmpty)
    }

    @Test func incompleteReturnsNil() throws {
        var buf = Array(Self.hello.prefix(3))
        #expect(try WSFrame.parse(&buf) == nil)
        #expect(buf == Array(Self.hello.prefix(3)))
    }

    @Test func encodes16BitLength() {
        let f = WSFrame(fin: true, opcode: 1, payload: [UInt8](repeating: 0x61, count: 300))
        let out = f.encode()
        #expect(Array(out.prefix(4)) == [0x81, 0x7E, 0x01, 0x2C])
        #expect(out.count == 304)
    }

    @Test func rejectsUnmasked() {
        var buf: [UInt8] = [0x81, 0x01, 0x61]
        #expect(throws: WSFrameError.self) { try WSFrame.parse(&buf) }
    }

    @Test func rejectsOversize() {
        var buf: [UInt8] = [0x82, 0xFF, 0, 0, 0, 0, 0x02, 0, 0, 0, 1, 2, 3, 4]
        #expect(throws: WSFrameError.self) { try WSFrame.parse(&buf) }
    }
}
