import Foundation

public enum StreamItem: Equatable {
    case sessionId(String)
    case textDelta(String)
    case toolUse(name: String, input: JSON)
    case result(isError: Bool, sessionId: String?)
    /// Error result with zero turns: what `--resume <unknown id>` prints instead of `init`, but also any
    /// other failure before the first turn. `ChatSession` decides, from stderr, whether the resume failed.
    case resumeFailed
}

/// `claude -p --input-format stream-json --output-format stream-json` line formats (spikes/chat/RESULTS.md).
public enum StreamJSON {
    public static func userLine(_ text: String) -> String {
        encode(.object([
            "type": .string("user"),
            "message": .object([
                "role": .string("user"),
                "content": .array([.object(["type": .string("text"), "text": .string(text)])]),
            ]),
        ]))
    }

    public static func interruptLine(id: String) -> String {
        encode(.object([
            "type": .string("control_request"),
            "request_id": .string(id),
            "request": .object(["subtype": .string("interrupt")]),
        ]))
    }

    /// Items of one stdout line; unknown or irrelevant lines give `[]`.
    public static func parse(_ line: String) -> [StreamItem] {
        guard let v = try? JSONDecoder().decode(JSON.self, from: Data(line.utf8)) else { return [] }
        switch v["type"]?.string {
        case "system":
            guard v["subtype"]?.string == "init", let id = v["session_id"]?.string else { return [] }
            return [.sessionId(id)]
        case "stream_event":
            guard let event = v["event"], event["type"]?.string == "content_block_delta",
                  let delta = event["delta"], delta["type"]?.string == "text_delta",
                  let text = delta["text"]?.string else { return [] }
            return [.textDelta(text)]
        case "assistant":
            guard case .array(let blocks)? = v["message"]?["content"] else { return [] }
            return blocks.compactMap { b in
                guard b["type"]?.string == "tool_use", let name = b["name"]?.string else { return nil }
                return .toolUse(name: name, input: b["input"] ?? .object([:]))
            }
        case "result":
            let isError = v["is_error"]?.bool ?? false
            if isError, v["num_turns"]?.int == 0 { return [.resumeFailed] }
            return [.result(isError: isError, sessionId: v["session_id"]?.string)]
        default:
            return []
        }
    }

    private static func encode(_ v: JSON) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try! enc.encode(v), as: UTF8.self)
    }
}
