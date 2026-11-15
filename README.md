# Safari Agent

Claude in Safari for Claude Code. Claude can open pages in your real Safari, read them, click, type, scroll and take screenshots, while you keep working. A visible Claude cursor and status badge show what it is doing. It runs on your Claude subscription through Claude Code, with no API key.

## How it works

- `extension/` is a Safari Web Extension (Manifest V2, persistent background page). It reads the page and performs DOM actions.
- `helper/` is a Swift binary, `safari-claude-helper`. It is the MCP server (`safari`) for Claude Code and a small daemon that launchd starts on demand. Clicks go through macOS Accessibility, so they are real (`isTrusted`) and do not bring Safari to the front.
- `app/` is the macOS container app that ships the extension.

## Install

1. Build and install the app: `DEVELOPMENT_TEAM=<your team id> scripts/build-app.sh`. A free Apple ID (Personal Team) is enough. Open `~/Applications/Safari Agent.app` once.
2. In Safari settings, enable the Safari Agent extension and allow it on all websites.
3. Install the helper: `cd helper && swift build -c release && .build/release/safari-claude-helper install`. This registers the LaunchAgent and the `safari` MCP server in Claude Code.
4. In System Settings, under Privacy & Security > Accessibility, enable `safari-claude-helper`.

Check the setup with `safari-claude-helper status`. Remove everything with `safari-claude-helper uninstall`.

## Safety

- Risky actions (payments, form submits, deletes, new sites) go through the `confirm_action` tool. Never allow it permanently, and never allow `mcp__safari__*` as a whole.
- Banking and password manager sites are blocked by default.
- Press Stop on the page badge or the toolbar button to halt the agent.

## Limitations

- Typing uses DOM events, because Safari does not report keyboard focus while it is in the background. Sites that accept only real key presses may ignore it.
- Screenshots work only for the active tab of a window.
- No chat panel inside Safari yet.
