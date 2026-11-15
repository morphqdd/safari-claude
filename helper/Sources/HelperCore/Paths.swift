import Foundation

public struct Paths {
    /// Base directory for all paths; defaults to the home directory. Overridable for tests.
    nonisolated(unsafe) public static var root: URL = FileManager.default.homeDirectoryForCurrentUser

    public static var support: URL {
        root.appendingPathComponent("Library/Application Support/SafariClaude", isDirectory: true)
    }
    public static var token: URL { support.appendingPathComponent("token") }
    /// Id of the chat's `claude` conversation, for `--resume`.
    public static var chatSession: URL { support.appendingPathComponent("chat-session") }
    /// Absolute path of the `claude` binary, recorded at install time.
    public static var claudePath: URL { support.appendingPathComponent("claude-path") }
    /// Working directory of the chat's `claude` process (also holds its MCP config).
    public static var workspace: URL { support.appendingPathComponent("workspace", isDirectory: true) }
    public static var plist: URL {
        root.appendingPathComponent("Library/LaunchAgents/dev.morphqdd.safari-claude.plist")
    }
    public static var installedBinary: URL {
        root.appendingPathComponent(".local/bin/safari-claude-helper")
    }
}
