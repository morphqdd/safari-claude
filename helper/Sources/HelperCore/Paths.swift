import Foundation

public struct Paths {
    /// Base directory for all paths; defaults to the home directory. Overridable for tests.
    nonisolated(unsafe) public static var root: URL = FileManager.default.homeDirectoryForCurrentUser

    public static var support: URL {
        root.appendingPathComponent("Library/Application Support/SafariClaude", isDirectory: true)
    }
    public static var token: URL { support.appendingPathComponent("token") }
    public static var plist: URL {
        root.appendingPathComponent("Library/LaunchAgents/dev.morphqdd.safari-claude.plist")
    }
    public static var installedBinary: URL {
        root.appendingPathComponent(".local/bin/safari-claude-helper")
    }
}
