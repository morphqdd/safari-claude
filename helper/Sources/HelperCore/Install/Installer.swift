import Foundation
import ApplicationServices

public enum Installer {
    public static let label = "dev.morphqdd.safari-claude"
    static let preferredClaude = "/opt/homebrew/bin/claude"

    public enum Failure: Error, CustomStringConvertible {
        case command(String, Int32, String)
        public var description: String {
            switch self { case .command(let c, let code, let err): return "\(c) завершилась с кодом \(code): \(err)" }
        }
    }

    // MARK: Pure helpers

    public static func plist(binary: URL) -> String {
        let log = Paths.root.appendingPathComponent("Library/Logs/SafariClaude.log").path
        let dict: [String: Any] = [
            "Label": label,
            "ProgramArguments": [binary.path, "daemon"],
            "Sockets": ["Listener": ["SockNodeName": "127.0.0.1", "SockServiceName": "47821", "SockType": "stream"]],
            "StandardErrorPath": log,
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        return String(decoding: data, as: UTF8.self)
    }

    /// First "Apple Development" identity hash from `security find-identity -v -p codesigning` output.
    public static func pickSigningIdentity(from output: String) -> String? {
        for line in output.split(separator: "\n") where line.contains("Apple Development") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count >= 2, parts[0].hasSuffix(")"), parts[1].count >= 8,
               parts[1].allSatisfy({ $0.isHexDigit }) { return String(parts[1]) }
        }
        return nil
    }

    public static func claudeAddArguments(binary: URL) -> [String] {
        ["mcp", "add", "--scope", "user", "safari", "--", binary.path, "mcp"]
    }

    public static func claudeExecutable(exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String {
        exists(preferredClaude) ? preferredClaude : "claude"
    }

    // MARK: Filesystem

    public static func writePlist(binary: URL, to file: URL = Paths.plist) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: Paths.root.appendingPathComponent("Library/Logs"), withIntermediateDirectories: true)
        try plist(binary: binary).write(to: file, atomically: true, encoding: .utf8)
    }

    public static func tokenPresent() -> Bool { FileManager.default.fileExists(atPath: Paths.token.path) }

    public static func removeFiles(_ urls: [URL] = [Paths.plist, Paths.installedBinary, Paths.token]) throws {
        let fm = FileManager.default
        for url in urls where fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    // MARK: Processes

    @discardableResult
    static func run(_ exe: String, _ args: [String]) -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = exe.hasPrefix("/") ? URL(fileURLWithPath: exe) : URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = exe.hasPrefix("/") ? args : [exe] + args
        let o = Pipe(), e = Pipe()
        p.standardOutput = o; p.standardError = e
        do { try p.run() } catch { return (127, "", "\(error)") }
        let out = o.fileHandleForReading.readDataToEndOfFile()
        let err = e.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }

    static func runChecked(_ exe: String, _ args: [String]) throws {
        let r = run(exe, args)
        if r.status != 0 { throw Failure.command(([exe] + args).joined(separator: " "), r.status, r.err) }
    }

    static var domain: String { "gui/\(getuid())" }

    // MARK: Commands

    public static func install(binarySource: URL) throws {
        let fm = FileManager.default
        let dest = Paths.installedBinary
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: binarySource, to: dest)
        print("Бинарник скопирован: \(dest.path)")

        if let id = pickSigningIdentity(from: run("security", ["find-identity", "-v", "-p", "codesigning"]).out) {
            try runChecked("codesign", ["--force", "-s", id, dest.path])
            print("Подписан сертификатом Apple Development (\(id))")
        } else {
            try runChecked("codesign", ["--force", "-s", "-", dest.path])
            print("⚠️ ad-hoc signature: Accessibility permission will reset on every rebuild")
        }

        _ = try Auth().loadOrCreateToken()
        print("Токен: \(Paths.token.path)")

        try writePlist(binary: dest)
        run("launchctl", ["bootout", "\(domain)/\(label)"])
        try runChecked("launchctl", ["bootstrap", domain, Paths.plist.path])
        print("LaunchAgent загружен: \(Paths.plist.path)")

        let claude = claudeExecutable()
        let args = claudeAddArguments(binary: dest)
        let r = run(claude, args)
        if r.status == 0 {
            print("MCP-сервер зарегистрирован в Claude Code")
        } else {
            print("⚠️ Не удалось выполнить регистрацию MCP (\(r.err.trimmingCharacters(in: .whitespacesAndNewlines))).")
            print("Выполните вручную:\n  \(([claude] + args).joined(separator: " "))")
        }

        print("""

        Осталось вручную:
          1. Системные настройки → Конфиденциальность и безопасность → Универсальный доступ: включите safari-claude-helper (\(dest.path)).
          2. Safari → Настройки → Расширения: включите «Safari Agent» и разрешите все сайты.
          3. Проверьте: safari-claude-helper status
        """)
    }

    public static func uninstall() throws {
        run("launchctl", ["bootout", "\(domain)/\(label)"])
        let claude = claudeExecutable()
        let r = run(claude, ["mcp", "remove", "--scope", "user", "safari"])
        if r.status != 0 { print("⚠️ claude mcp remove не выполнено; при необходимости: \(claude) mcp remove --scope user safari") }
        try removeFiles()
        print("Удалено: LaunchAgent, бинарник, токен. Приложение Safari Agent удалите вручную из ~/Applications.")
    }

    public static func axTrusted() -> Bool { AXIsProcessTrusted() }

    public static func status() -> String {
        var lines: [String] = []
        let loaded = run("launchctl", ["print", "\(domain)/\(label)"]).status == 0
        lines.append("LaunchAgent: \(loaded ? "загружен" : "не загружен")")

        let bin = Paths.installedBinary
        var ax = "бинарник не установлен"
        if FileManager.default.isExecutableFile(atPath: bin.path) {
            let out = run(bin.path, ["status", "--check-ax"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
            ax = out == "trusted" ? "доступ выдан" : "доступ НЕ выдан"
        }
        lines.append("Accessibility: \(ax)")
        lines.append("Токен: \(tokenPresent() ? "есть" : "нет")")

        var ext = "неизвестно"
        if let token = try? Auth().loadOrCreateToken(), loaded {
            let box = ResultBox()
            let sem = DispatchSemaphore(value: 0)
            Task {
                box.value = try? await DaemonClient(token: token, timeout: 5).extensionConnected()
                sem.signal()
            }
            if sem.wait(timeout: .now() + 8) == .success, let v = box.value { ext = v ? "подключено" : "не подключено" }
        }
        lines.append("Расширение Safari: \(ext)")
        return lines.joined(separator: "\n")
    }

    private final class ResultBox: @unchecked Sendable { var value: Bool? }
}
