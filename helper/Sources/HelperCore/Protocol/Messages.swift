import Foundation

public enum Role: String, Codable, Equatable {
    case extension_ = "extension"
    case mcp
}

public indirect enum JSON: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSON].self) { self = .array(v) }
        else if let v = try? c.decode([String: JSON].self) { self = .object(v) }
        else { throw DecodingError.dataCorruptedError(in: c, debugDescription: "unsupported JSON value") }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    public subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var int: Int? {
        if case .number(let v) = self, v == v.rounded(), abs(v) < 9e15 { return Int(v) }
        return nil
    }
}

public struct RPCError: Codable, Equatable, Error, Sendable {
    public var code: String
    public var message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public static func busy(_ message: String = "busy") -> RPCError { .init(code: "busy", message: message) }
    public static func noExtension(_ message: String = "no_extension") -> RPCError { .init(code: "no_extension", message: message) }
    public static func noAgentTab(_ message: String = "no_agent_tab") -> RPCError { .init(code: "no_agent_tab", message: message) }
    public static func siteNotAllowed(_ message: String = "site_not_allowed") -> RPCError { .init(code: "site_not_allowed", message: message) }
    public static func riskyRequiresConfirmation(_ message: String = "risky_requires_confirmation") -> RPCError { .init(code: "risky_requires_confirmation", message: message) }
    public static func notFound(_ message: String = "not_found") -> RPCError { .init(code: "not_found", message: message) }
    public static func backgroundTab(_ message: String = "background_tab") -> RPCError { .init(code: "background_tab", message: message) }
    public static func cancelled(_ message: String = "cancelled") -> RPCError { .init(code: "cancelled", message: message) }
    public static func timeout(_ message: String = "timeout") -> RPCError { .init(code: "timeout", message: message) }
    public static func badRequest(_ message: String = "bad_request") -> RPCError { .init(code: "bad_request", message: message) }
    public static func `internal`(_ message: String = "internal") -> RPCError { .init(code: "internal", message: message) }
}

public enum Message: Codable, Equatable {
    case hello(role: Role, token: String?, chat: String? = nil)
    case welcome
    case req(id: Int, method: String, params: JSON)
    case res(id: Int, result: JSON?, error: RPCError?)
    case event(name: String, data: JSON)

    private enum Keys: String, CodingKey {
        case type, role, token, chat, id, method, params, result, error, name, data
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let type = try c.decode(String.self, forKey: .type)
        switch type {
        case "hello":
            self = .hello(role: try c.decode(Role.self, forKey: .role),
                          token: try c.decodeIfPresent(String.self, forKey: .token),
                          chat: try c.decodeIfPresent(String.self, forKey: .chat))
        case "welcome":
            self = .welcome
        case "req":
            self = .req(id: try c.decode(Int.self, forKey: .id),
                        method: try c.decode(String.self, forKey: .method),
                        params: try c.decodeIfPresent(JSON.self, forKey: .params) ?? .object([:]))
        case "res":
            self = .res(id: try c.decode(Int.self, forKey: .id),
                        result: try c.decodeIfPresent(JSON.self, forKey: .result),
                        error: try c.decodeIfPresent(RPCError.self, forKey: .error))
        case "event":
            self = .event(name: try c.decode(String.self, forKey: .name),
                          data: try c.decodeIfPresent(JSON.self, forKey: .data) ?? .object([:]))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown message type \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .hello(let role, let token, let chat):
            try c.encode("hello", forKey: .type)
            try c.encode(role, forKey: .role)
            try c.encodeIfPresent(token, forKey: .token)
            try c.encodeIfPresent(chat, forKey: .chat)
        case .welcome:
            try c.encode("welcome", forKey: .type)
        case .req(let id, let method, let params):
            try c.encode("req", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encode(method, forKey: .method)
            try c.encode(params, forKey: .params)
        case .res(let id, let result, let error):
            try c.encode("res", forKey: .type)
            try c.encode(id, forKey: .id)
            try c.encodeIfPresent(result, forKey: .result)
            try c.encodeIfPresent(error, forKey: .error)
        case .event(let name, let data):
            try c.encode("event", forKey: .type)
            try c.encode(name, forKey: .name)
            try c.encode(data, forKey: .data)
        }
    }
}
