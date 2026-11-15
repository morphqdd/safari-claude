import Testing
import Foundation
@testable import HelperCore

/// Lines follow the formats recorded in spikes/chat/RESULTS.md.
@Suite struct StreamJSONTests {
    @Test func initGivesSessionId() {
        let line = #"{"type":"system","subtype":"init","session_id":"0b5c-11","tools":["mcp__safari__ping"],"mcp_servers":[{"name":"safari","status":"connected"}]}"#
        #expect(StreamJSON.parse(line) == [.sessionId("0b5c-11")])
    }

    @Test func otherSystemAndRateLimitLinesAreIgnored() {
        #expect(StreamJSON.parse(#"{"type":"system","subtype":"status","session_id":"x"}"#) == [])
        #expect(StreamJSON.parse(#"{"type":"system","subtype":"hook_started","session_id":"x"}"#) == [])
        #expect(StreamJSON.parse(#"{"type":"rate_limit_event","rate_limit_info":{}}"#) == [])
        #expect(StreamJSON.parse(#"{"type":"control_response","response":{"subtype":"success","request_id":"r1"}}"#) == [])
        #expect(StreamJSON.parse("not json") == [])
        #expect(StreamJSON.parse("") == [])
    }

    @Test func textDelta() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Привет"}}}"#
        #expect(StreamJSON.parse(line) == [.textDelta("Привет")])
    }

    @Test func inputJsonDeltaAndOtherStreamEventsAreIgnored() {
        #expect(StreamJSON.parse(#"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"a\""}}}"#) == [])
        #expect(StreamJSON.parse(#"{"type":"stream_event","event":{"type":"message_start","message":{}}}"#) == [])
    }

    @Test func toolUseFromAssistantMessageSkipsTextBlocks() {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Сейчас"},{"type":"tool_use","id":"toolu_1","name":"mcp__safari__ping","input":{}},{"type":"tool_use","id":"toolu_2","name":"mcp__safari__open","input":{"url":"https://a.b"}}]}}"#
        #expect(StreamJSON.parse(line) == [
            .toolUse(name: "mcp__safari__ping", input: .object([:])),
            .toolUse(name: "mcp__safari__open", input: .object(["url": .string("https://a.b")])),
        ])
    }

    @Test func successResult() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"num_turns":1,"session_id":"s-1","result":"ok"}"#
        #expect(StreamJSON.parse(line) == [.result(isError: false, sessionId: "s-1")])
    }

    @Test func interruptedResultIsAnErrorResult() {
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":1,"session_id":"s-1"}"#
        #expect(StreamJSON.parse(line) == [.result(isError: true, sessionId: "s-1")])
    }

    @Test func zeroTurnErrorResultIsResumeFailed() {
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,"session_id":"new-1"}"#
        #expect(StreamJSON.parse(line) == [.resumeFailed])
    }

    @Test func userLineIsOneJSONLine() throws {
        let line = StreamJSON.userLine("строка 1\nстрока \"2\"")
        #expect(!line.contains("\n"))
        let decoded = try JSONDecoder().decode(JSON.self, from: Data(line.utf8))
        #expect(decoded == .object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object(["type": .string("text"), "text": .string("строка 1\nстрока \"2\"")])]),
            ]),
        ]))
    }

    @Test func interruptLineIsControlRequest() throws {
        let line = StreamJSON.interruptLine(id: "r1")
        #expect(!line.contains("\n"))
        let decoded = try JSONDecoder().decode(JSON.self, from: Data(line.utf8))
        #expect(decoded == .object([
            "type": .string("control_request"),
            "request_id": .string("r1"),
            "request": .object(["subtype": .string("interrupt")]),
        ]))
    }
}
