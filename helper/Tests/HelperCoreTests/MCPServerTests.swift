import XCTest
@testable import HelperCore

final class MCPServerTests: XCTestCase {
    private func decode(_ s: String?) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: Data(try XCTUnwrap(s).utf8))
    }

    func testInitializeEchoesVersion() async throws {
        let server = MCPServer(forward: { _, _ in .null })
        let line = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}"#
        let reply = try decode(await server.handle(line: line))
        XCTAssertEqual(reply["result"]?["serverInfo"]?["name"]?.string, "safari")
        XCTAssertEqual(reply["result"]?["protocolVersion"]?.string, "2024-11-05")
        XCTAssertEqual(reply["id"]?.int, 1)
    }

    func testToolsListHasAllTools() async throws {
        let server = MCPServer(forward: { _, _ in .null })
        let reply = try decode(await server.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        guard case .array(let tools)? = reply["result"]?["tools"] else { return XCTFail("no tools") }
        let names = Set(tools.compactMap { $0["name"]?.string })
        XCTAssertEqual(names, ["tabs_list", "tab_create", "tab_select", "navigate", "read_page", "find",
                               "get_text", "click", "type", "key", "scroll", "screenshot", "wait", "confirm_action"])
        XCTAssertEqual(tools.count, 14)
    }

    func testToolErrorIsContentNotRpcError() async throws {
        let server = MCPServer(forward: { _, _ in throw RPCError.busy() })
        let line = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"click","arguments":{"ref":"e1"}}}"#
        let reply = try decode(await server.handle(line: line))
        XCTAssertNil(reply["error"])
        XCTAssertEqual(reply["result"]?["isError"]?.bool, true)
        guard case .array(let content)? = reply["result"]?["content"] else { return XCTFail("no content") }
        XCTAssertTrue(content[0]["text"]?.string?.hasPrefix("busy:") ?? false)
    }

    func testInitializedNotificationNoReply() async {
        let server = MCPServer(forward: { _, _ in .null })
        let reply = await server.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        XCTAssertNil(reply)
    }
}
