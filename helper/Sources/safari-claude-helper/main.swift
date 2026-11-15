import Foundation
import HelperCore

func notImplemented(_ name: String) -> Never {
    FileHandle.standardError.write(Data("\(name): not implemented\n".utf8))
    exit(1)
}

func runDaemon() -> Never { notImplemented("daemon") }
func runMCP() -> Never { notImplemented("mcp") }
func runInstall() -> Never { notImplemented("install") }
func runUninstall() -> Never { notImplemented("uninstall") }
func runStatus() -> Never { notImplemented("status") }

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
