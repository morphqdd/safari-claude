import Testing
import Foundation
@testable import HelperCore

@Suite struct InstallerTests {
    let binary = URL(fileURLWithPath: "/Users/x/.local/bin/safari-claude-helper")

    func parsed() throws -> [String: Any] {
        let data = Data(Installer.plist(binary: binary).utf8)
        return try #require(try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    @Test func plistHasSocketAndNoKeepAlive() throws {
        let p = try parsed()
        #expect(p["Label"] as? String == "dev.morphqdd.safari-claude")
        let listener = try #require(((p["Sockets"] as? [String: Any])?["Listener"]) as? [String: Any])
        #expect(listener["SockServiceName"] as? String == "47821")
        #expect(listener["SockNodeName"] as? String == "127.0.0.1")
        #expect(listener["SockType"] as? String == "stream")
        #expect(p["KeepAlive"] == nil)
        #expect(p["RunAtLoad"] == nil)
        #expect((p["StandardErrorPath"] as? String)?.hasSuffix("/Library/Logs/SafariClaude.log") == true)
    }

    @Test func plistRunsDaemonMode() throws {
        #expect(try parsed()["ProgramArguments"] as? [String] == [binary.path, "daemon"])
    }

    @Test func picksFirstAppleDevelopmentIdentity() {
        let out = """
          1) AAAA1111 "Developer ID Application: Foo (T1)"
          2) BBBB2222 "Apple Development: me@example.com (T2)"
          3) CCCC3333 "Apple Development: other@example.com (T3)"
             3 valid identities found
        """
        #expect(Installer.pickSigningIdentity(from: out) == "BBBB2222")
    }

    @Test func noIdentityMeansAdHoc() {
        #expect(Installer.pickSigningIdentity(from: "     0 valid identities found\n") == nil)
        #expect(Installer.pickSigningIdentity(from: "") == nil)
    }

    @Test func claudeAddArguments() {
        #expect(Installer.claudeAddArguments(binary: binary) ==
                ["mcp", "add", "--scope", "user", "safari", "--", binary.path, "mcp"])
    }

    @Test func claudeExecutableFallsBackToPath() {
        #expect(Installer.claudeExecutable(exists: { _ in true }) == "/opt/homebrew/bin/claude")
        #expect(Installer.claudeExecutable(exists: { _ in false }) == "claude")
    }

    @Test func writesAndRemovesPlist() throws {
        // Explicit paths: never mutates the global Paths.root (other suites run in parallel).
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-inst-\(UUID().uuidString)")
        let file = dir.appendingPathComponent("LaunchAgents/x.plist")
        try Installer.writePlist(binary: binary, to: file)
        #expect(try String(contentsOf: file, encoding: .utf8) == Installer.plist(binary: binary))
        try Installer.removeFiles([file, dir.appendingPathComponent("absent")])
        #expect(!FileManager.default.fileExists(atPath: file.path))
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func installSkipsCopyWhenRunFromInstalledBinary() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sc-same-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("safari-claude-helper")
        FileManager.default.createFile(atPath: bin.path, contents: Data("x".utf8))
        let link = dir.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bin)
        #expect(!Installer.needsCopy(source: bin, destination: bin))
        #expect(!Installer.needsCopy(source: URL(fileURLWithPath: dir.path + "/./safari-claude-helper"), destination: bin))
        #expect(!Installer.needsCopy(source: link, destination: bin))
        #expect(Installer.needsCopy(source: URL(fileURLWithPath: "/tmp/other/safari-claude-helper"), destination: bin))
    }

    @Test func currentExecutableIsAbsolute() {
        let u = Installer.currentExecutable()
        #expect(u.path.hasPrefix("/"))
        #expect(FileManager.default.fileExists(atPath: u.path))
    }

    @Test func mcpAddAlreadyExistsIsRecognized() {
        #expect(Installer.alreadyRegistered("MCP server safari already exists in user config"))
        #expect(!Installer.alreadyRegistered("command not found"))
    }
}
