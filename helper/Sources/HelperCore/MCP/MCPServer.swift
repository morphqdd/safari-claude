import Foundation

/// Newline-delimited JSON-RPC 2.0 MCP server; tool calls go through `forward`.
public final class MCPServer {
    private let forward: (String, JSON) async throws -> JSON

    public init(forward: @escaping (String, JSON) async throws -> JSON) {
        self.forward = forward
    }

    /// Handles one input line; returns the reply line, or nil for notifications.
    public func handle(line: String) async -> String? {
        guard let msg = try? JSONDecoder().decode(JSON.self, from: Data(line.utf8)),
              case .object = msg, let method = msg["method"]?.string else {
            return encode(["jsonrpc": .string("2.0"), "id": .null,
                           "error": rpcError(-32700, "parse error")])
        }
        guard let id = msg["id"] else { return nil } // notification
        let params = msg["params"] ?? .object([:])
        let result: JSON
        switch method {
        case "initialize":
            result = .object([
                "protocolVersion": .string(params["protocolVersion"]?.string ?? "2025-06-18"),
                "capabilities": .object(["tools": .object([:])]),
                "serverInfo": .object(["name": .string("safari"), "version": .string("0.1.0")]),
            ])
        case "ping":
            result = .object([:])
        case "tools/list":
            result = .object(["tools": .array(ToolCatalog.tools)])
        case "tools/call":
            result = await callTool(params)
        default:
            return encode(["jsonrpc": .string("2.0"), "id": id,
                           "error": rpcError(-32601, "method not found: \(method)")])
        }
        return encode(["jsonrpc": .string("2.0"), "id": id, "result": result])
    }

    private func callTool(_ params: JSON) async -> JSON {
        guard let name = params["name"]?.string, ToolCatalog.names.contains(name) else {
            return Self.toolError(code: "bad_request",
                                  message: "unknown tool \(params["name"]?.string ?? "")")
        }
        do {
            return try await forward(name, params["arguments"] ?? .object([:]))
        } catch let e as RPCError {
            return Self.toolError(code: e.code, message: e.message)
        } catch {
            return Self.toolError(code: "internal", message: "\(error)")
        }
    }

    static func toolError(code: String, message: String) -> JSON {
        .object(["content": .array([.object(["type": .string("text"), "text": .string("\(code): \(message)")])]),
                 "isError": .bool(true)])
    }

    private func rpcError(_ code: Int, _ message: String) -> JSON {
        .object(["code": .number(Double(code)), "message": .string(message)])
    }

    private func encode(_ o: [String: JSON]) -> String? {
        let enc = JSONEncoder()
        enc.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? enc.encode(JSON.object(o)) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
