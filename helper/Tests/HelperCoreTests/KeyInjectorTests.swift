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

    @Test func keyEventMapping() {
        func ev(_ s: String) -> (CGKeyCode, [UInt16]?) {
            let e = KeyInjector.keyEvent(for: Array(s.utf16)); return (e.key, e.unicode)
        }
        #expect(ev("\n") == (36, nil))
        #expect(ev("\r\n") == (36, nil))
        #expect(ev("\t") == (48, nil))
        #expect(ev("a") == (0, [0x61]))
        #expect(ev("Я") == (0, [0x042F]))
    }

    @Test func keyUpAlwaysFollowsPostedKeyDown() throws {
        var front = false
        var events: [Bool] = []
        try KeyInjector.pair(isFrontmost: { front }) { down in
            events.append(down)
            front = true // Safari becomes frontmost right after the keyDown
        }
        #expect(events == [true, false])
    }

    @Test func frontmostBeforeKeyDownPostsNothing() {
        var events: [Bool] = []
        #expect(throws: RPCError.self) { try KeyInjector.pair(isFrontmost: { true }) { events.append($0) } }
        #expect(events.isEmpty)
    }

    @Test func typeChunksStopsOnCancel() {
        var posted: [[UInt16]] = []
        do {
            try KeyInjector.typeChunks("abcd", isCancelled: { posted.count >= 2 }) { posted.append($0) }
            Issue.record("expected cancel")
        } catch let e as RPCError {
            #expect(e.code == "cancelled")
            #expect(e.message == "Пользователь нажал «Стоп»")
        } catch { Issue.record("unexpected \(error)") }
        #expect(posted == [[0x61], [0x62]])
    }
}
