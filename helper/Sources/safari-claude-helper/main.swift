import Foundation
import HelperCore

func runDaemon() -> Never {
    var devPort: UInt16?
    let args = Array(CommandLine.arguments.dropFirst(2))
    if let i = args.firstIndex(of: "--dev-port"), i + 1 < args.count { devPort = UInt16(args[i + 1]) }
    do {
        let daemon = Daemon(auth: Auth(), tools: ToolRunner(actuator: AXActuator()))
        try daemon.serve(devPort: devPort)
        withExtendedLifetime(daemon) { dispatchMain() }
    } catch {
        FileHandle.standardError.write(Data("daemon: \(error)\n".utf8))
        exit(1)
    }
}
func runMCP() -> Never {
    var port: UInt16 = 47821
    let args = Array(CommandLine.arguments.dropFirst(2))
    if let i = args.firstIndex(of: "--port"), i + 1 < args.count, let p = UInt16(args[i + 1]) { port = p }
    let token: String
    do { token = try Auth().loadOrCreateToken() } catch {
        FileHandle.standardError.write(Data("mcp: cannot load token: \(error)\n".utf8))
        exit(1)
    }
    let client = DaemonClient(port: port, token: token)
    let server = MCPServer(forward: { name, args in try await client.call(name, args) })
    Task {
        do {
            for try await line in FileHandle.standardInput.bytes.lines where !line.isEmpty {
                if let reply = await server.handle(line: line) {
                    FileHandle.standardOutput.write(Data((reply + "\n").utf8))
                }
            }
        } catch {
            FileHandle.standardError.write(Data("mcp: stdin error: \(error)\n".utf8))
        }
        exit(0)
    }
    dispatchMain()
}
func runInstall() -> Never {
    do { try Installer.install(binarySource: Installer.currentExecutable()) }
    catch { FileHandle.standardError.write(Data("install: \(error)\n".utf8)); exit(1) }
    exit(0)
}
func runUninstall() -> Never {
    do { try Installer.uninstall() }
    catch { FileHandle.standardError.write(Data("uninstall: \(error)\n".utf8)); exit(1) }
    exit(0)
}
func runStatus() -> Never {
    if CommandLine.arguments.contains("--check-ax") {
        print(Installer.axTrusted() ? "trusted" : "not trusted")
    } else {
        print(Installer.status())
    }
    exit(0)
}

let usage = "usage: safari-claude-helper <daemon|mcp|install|uninstall|status>\n"

switch CommandLine.arguments.dropFirst().first {
case "daemon": runDaemon()
case "mcp": runMCP()
case "install": runInstall()
case "uninstall": runUninstall()
case "status": runStatus()
default:
    FileHandle.standardError.write(Data(usage.utf8))
    exit(2)
}
