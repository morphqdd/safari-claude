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

    /// `claude mcp add` output meaning the server is already registered.
    static func alreadyRegistered(_ output: String) -> Bool {
        output.lowercased().contains("already exists")
    }

    public static func claudeExecutable(exists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) -> String {
        exists(preferredClaude) ? preferredClaude : "claude"
    }

    /// Absolute path of `claude`: the preferred location, else what `which` finds, else the bare name.
    static func resolveClaude() -> String {
        if FileManager.default.isExecutableFile(atPath: preferredClaude) { return preferredClaude }
        let found = run("/usr/bin/which", ["claude"]).out.trimmingCharacters(in: .whitespacesAndNewlines)
        return found.hasPrefix("/") ? found : claudeExecutable()
    }

    public static func writeClaudePath(_ path: String, to file: URL = Paths.claudePath) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try path.write(to: file, atomically: true, encoding: .utf8)
    }

    /// The daemon runs under launchd without the user's PATH, so it reads the path saved at install.
    public static func readClaudePath(from file: URL = Paths.claudePath) -> String {
        let saved = (try? String(contentsOf: file, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return saved.isEmpty ? claudeExecutable() : saved
    }

    /// False when `source` already is `destination` (running `install` from the installed binary).
    public static func needsCopy(source: URL, destination: URL) -> Bool {
        source.standardizedFileURL.resolvingSymlinksInPath().path
            != destination.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Absolute path of the running executable (not argv[0], which may be relative or a bare name from PATH).
    public static func currentExecutable() -> URL {
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buf = [CChar](repeating: 0, count: Int(size) + 1)
        if _NSGetExecutablePath(&buf, &size) == 0 {
            return URL(fileURLWithPath: String(cString: buf)).standardizedFileURL.resolvingSymlinksInPath()
        }
        return (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
            .standardizedFileURL.resolvingSymlinksInPath()
    }

    // MARK: Filesystem

    public static func writePlist(binary: URL, to file: URL = Paths.plist) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: Paths.root.appendingPathComponent("Library/Logs"), withIntermediateDirectories: true)
        try plist(binary: binary).write(to: file, atomically: true, encoding: .utf8)
    }

    public static func tokenPresent() -> Bool { FileManager.default.fileExists(atPath: Paths.token.path) }

    public static func removeFiles(_ urls: [URL] = [Paths.plist, Paths.installedBinary, Paths.token,
                                              Paths.claudePath, Paths.chatSession, Paths.workspace]) throws {
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

    static func sign(_ dest: URL) throws {
        if let id = pickSigningIdentity(from: run("security", ["find-identity", "-v", "-p", "codesigning"]).out) {
            try runChecked("codesign", ["--force", "-s", id, dest.path])
            print("Подписан сертификатом Apple Development (\(id))")
        } else {
            try runChecked("codesign", ["--force", "-s", "-", dest.path])
            print("⚠️ ad-hoc signature: Accessibility permission will reset on every rebuild")
        }
    }

    public static func install(binarySource: URL) throws {
        let fm = FileManager.default
        let dest = Paths.installedBinary
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if needsCopy(source: binarySource, destination: dest) {
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: binarySource, to: dest)
            print("Бинарник скопирован: \(dest.path)")
            try sign(dest)
        } else {
            // Re-signing the running binary in place is unsafe; it was signed when first installed.
            print("Запущен установленный бинарник: копирование и подпись пропущены (\(dest.path))")
        }

        _ = try Auth().loadOrCreateToken()
        print("Токен: \(Paths.token.path)")

        try writePlist(binary: dest)
        run("launchctl", ["bootout", "\(domain)/\(label)"])
        try runChecked("launchctl", ["bootstrap", domain, Paths.plist.path])
        print("LaunchAgent загружен: \(Paths.plist.path)")

        let claude = resolveClaude()
        try? writeClaudePath(claude)
        let args = claudeAddArguments(binary: dest)
        let r = run(claude, args)
        if r.status == 0 {
            print("MCP-сервер зарегистрирован в Claude Code")
        } else if alreadyRegistered(r.err + r.out) {
            print("MCP-сервер уже зарегистрирован")
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
        print("Удалено: LaunchAgent, бинарник, токен, данные чата. Приложение Safari Agent удалите вручную из ~/Applications.")
    }

    public static func status() -> String {
        var lines: [String] = []
        let loaded = run("launchctl", ["print", "\(domain)/\(label)"]).status == 0
        lines.append("LaunchAgent: \(loaded ? "загружен" : "не загружен")")

        lines.append("Токен: \(tokenPresent() ? "есть" : "нет")")

        // Asked of the daemon itself: this CLI runs under the terminal, whose permission differs.
        var ax = "неизвестно (демон не ответил)"
        var ext = "неизвестно"
        if let token = try? Auth().loadOrCreateToken(), loaded {
            let box = ResultBox()
            let sem = DispatchSemaphore(value: 0)
            Task {
                box.value = try? await DaemonClient(token: token, timeout: 5).daemonStatus()
                sem.signal()
            }
            if sem.wait(timeout: .now() + 8) == .success, let v = box.value {
                ax = v.axTrusted ? "доступ выдан" : "доступ НЕ выдан"
                ext = v.extensionConnected ? "подключено" : "не подключено"
            }
        }
        lines.append("Accessibility (демон): \(ax)")
        lines.append("Расширение Safari: \(ext)")
        return lines.joined(separator: "\n")
    }

    private final class ResultBox: @unchecked Sendable { var value: (extensionConnected: Bool, axTrusted: Bool)? }
}
