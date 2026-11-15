# Chat window spike: results (2026-11-15, macOS 26.6, Safari 26.6, Claude Code 2.1.311)

| Probe | Result |
|---|---|
| `windows.create({type: "popup", width: 400, height, left, top})` | OK. Window type `popup`, size and position respected (placed flush right of the last-focused window). |
| Extension page in that window | OK after registering `Resources/chat` in `project.xcproj`: new extension folders are NOT copied into the appex unless listed there. |
| Popup window after Safari quit/relaunch | Not restored. The chat history must come from storage. |
| `commands` `open-chat` = `MacCtrl+Shift+K` | OK, `onCommand(name, tab)` fires with the active tab. |
| `contextMenus` (permission `contextMenus`; `browser.menus` is absent) | OK, `onClicked(info, tab)` gives `info.menuItemId` and the tab. **Non-ASCII titles are garbled by Safari** even when passed as correct JS strings (`\u` escapes): use an ASCII title. |
| Chat page port | `runtime.connect({name: "chat"})` from the page works. `port.sender.url` = `safari-web-extension://<UUID>/chat/...` with an UPPERCASE UUID; `port.sender.tab` IS set (the popup is a tab). |
| stream-json user message (stdin) | `{"type":"user","message":{"role":"user","content":[{"type":"text","text":"..."}]}}` one per line. |
| Output: session id | `{"type":"system","subtype":"init","session_id":"<uuid>","tools":[...],"mcp_servers":[...]}`. Other `system` subtypes (`status`, `hook_*`) and `rate_limit_event` appear and must be ignored. |
| Output: text deltas | `{"type":"stream_event","event":{"type":"content_block_delta","delta":{"type":"text_delta","text":"..."}}}` (requires `--include-partial-messages`). Tool-input deltas have `delta.type` = `input_json_delta` and must be ignored. |
| Output: tool use | `{"type":"assistant","message":{"content":[{"type":"tool_use","id":"...","name":"mcp__safari__ping","input":{}}]}}`. Assistant text also repeats here as `{"type":"text"}` blocks (already streamed as deltas). |
| Output: end of turn | `{"type":"result","subtype":"success","is_error":false,"session_id":"<uuid>","result":"..."}`. |
| Interrupt | stdin `{"type":"control_request","request_id":"<id>","request":{"subtype":"interrupt"}}` -> `{"type":"control_response","response":{"subtype":"success","request_id":"<id>",...}}`, then `result` with `subtype` `error_during_execution`, `is_error` true. **Process stays alive** and accepts the next user message. |
| `--resume <valid id>` | OK, init carries the same session id, earlier context is remembered. |
| `--resume <unknown id>` | Immediate `{"type":"result","subtype":"error_during_execution","is_error":true,"num_turns":0,...}` with NO prior `init`, stderr `No conversation found with session ID: <id>`, exit code 1. |
| Permissions | `--tools "" --allowedTools "mcp__safari__*"`: MCP tool ran with no prompt; init `tools` lists only the MCP tools. No `bypassPermissions` needed. |
| MCP env | `env` in the `--mcp-config` server entry reaches the server process (`SC_CHAT_KEY` seen). |
| User hooks and plugins | Without isolation the owner's SessionStart hooks run inside the chat session. `--setting-sources ""` removes them (no `hook_*` events, 0 skills); login still works. `--bare` is NOT usable: it never reads OAuth/keychain. |
| launchd-like env | `env -i HOME=$HOME PATH=/usr/bin:/bin USER=$USER <abs claude path> -p ...` logs in and works. |

## Consequences for the plan

- Chat flags (binding for Task 3): `-p --input-format stream-json --output-format stream-json --include-partial-messages --verbose --setting-sources "" --disable-slash-commands --strict-mcp-config --mcp-config <file> --tools "" --allowedTools "mcp__safari__*" --append-system-prompt <CHAT_PROMPT> [--resume <id>]`.
- `StreamItem.resumeFailed` = a `result` with `is_error` true before any `init` while resuming. An interrupted turn's `result` (`error_during_execution` after `init`) is a normal turn end, not an error.
- `ChatSession.interrupt()` uses the control request (process stays alive).
- The launch environment passes `HOME`, `USER`, `PATH` through; the claude path must be absolute.
- Context menu title: `Ask Claude about this page` (ASCII). All other chat UI text stays Russian (it lives in the UTF-8 chat page).
- Task 6 port check: compare `sender.url` against `runtime.getURL("chat/")` case-insensitively; do not rely on `sender.tab` being absent.
- Task 6/7: `Resources/chat` is registered in `project.xcproj` (done in this spike).
