import CoreGraphics
import Testing
@testable import HelperCore

@Suite struct KeyInjectorTests {
    @Test func chunksKeepSurrogatePairs() {
        let c = KeyInjector.chunks("Пр😀👍🏽")
        #expect(c.count == 4)
        #expect(c[2] == [0xD83D, 0xDE00])
        #expect(c[3].count == 4)
    }

    @Test func parsesCombos() throws {
        let a = try KeyCombo.parse("Cmd+Shift+a")
        #expect(a.key == "a")
        #expect(a.modifiers == [.maskCommand, .maskShift])
        let b = try KeyCombo.parse("enter")
        #expect(b.key == "Enter")
        #expect(b.modifiers == [])
        #expect(throws: RPCError.self) { try KeyCombo.parse("Hyper+x") }
    }

    @Test func virtualKeys() {
        #expect(KeyInjector.virtualKey(for: "Enter") == 36)
        #expect(KeyInjector.virtualKey(for: "Tab") == 48)
        #expect(KeyInjector.virtualKey(for: "a") == 0)
        #expect(KeyInjector.virtualKey(for: "z") == 6)
        #expect(KeyInjector.virtualKey(for: "ArrowLeft") == 123)
    }
}
