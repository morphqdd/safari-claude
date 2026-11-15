import Foundation
import Testing
@testable import HelperCore

@Suite struct AXLiveTests {
    @Test func pressesMarkedButtonWithoutActivating() async throws {
        guard ProcessInfo.processInfo.environment["SC_LIVE_AX"] == "1" else {
            print("SKIP AXLive: SC_LIVE_AX != 1")
            return
        }
        var tries = 0
        while Frontmost.isSafari() {
            tries += 1
            if tries >= 3 {
                print("SKIP AXLive: Safari is frontmost (owner using it); live test NOT run")
                return
            }
            try await Task.sleep(for: .seconds(5))
        }

        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let server = root.appendingPathComponent("tests/fixtures/server.py").path
        let logPath = NSTemporaryDirectory() + "sc-ax-live-\(UUID().uuidString).log"
        FileManager.default.createFile(atPath: logPath, contents: nil)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        proc.arguments = [server, logPath]
        try proc.run()
        defer { proc.terminate() }

        func log() -> String { (try? String(contentsOfFile: logPath, encoding: .utf8)) ?? "" }
        func wait(_ secs: Int, _ cond: () -> Bool) async throws -> Bool {
            for _ in 0..<(secs * 4) { if cond() { return true }; try await Task.sleep(for: .milliseconds(250)) }
            return cond()
        }
        try await Task.sleep(for: .seconds(1))

        let url = "http://127.0.0.1:47830/?w=live&mark=btn"
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = ["-g", "-a", "Safari", url]
        try open.run(); open.waitUntilExit()
        #expect(try await wait(15) { log().contains("\"loaded\"") })
        #expect(!Frontmost.isSafari())

        let act = AXActuator()
        var pressed = false
        for _ in 0..<20 {
            if (try? act.press(marker: "__sc_m_live", pageURL: url)) != nil { pressed = true; break }
            try await Task.sleep(for: .milliseconds(500))
        }
        #expect(pressed)
        #expect(try await wait(5) { log().contains("\"type\": \"click\"") || log().contains("\"type\":\"click\"") })
        let clickLine = log().split(separator: "\n").first { $0.contains("\"click\"") }.map(String.init) ?? ""
        #expect(clickLine.contains("\"isTrusted\":true"))
        #expect(!act.isSafariFrontmost())
        #expect(throws: RPCError.self) { try act.press(marker: "__sc_m_absent", pageURL: url) }
        #expect(throws: RPCError.self) { try act.press(marker: "__sc_m_live", pageURL: "http://127.0.0.1:1/nope") }
    }
}
