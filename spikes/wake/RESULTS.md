# Wake / keep-alive spike — results (2026-11-15, macOS 26.6, Safari 26.6)

| Probe | Result |
|---|---|
| Manifest `commands` with 3 modifiers (`MacCtrl+Shift+Alt+Y`) | ❌ Safari rejects the whole manifest: "invalid suggested_key". 2 modifiers (`MacCtrl+Shift+Y`) are accepted. |
| MV3 `background.service_worker` | ⚠️ The worker loads, but `action.onClicked` / `commands.onCommand` never reach it. |
| MV3 `background.scripts` + `persistent:false` | ✅ Events arrive (`onClicked`, `onCommand` when Safari is frontmost). ❌ The page unloads ~60–70 s after load despite open WebSocket, 20 s pings and JS messages. |
| A. Wake by posting the shortcut via `postToPid` while Safari is in the background | ❌ No `onCommand`. The shortcut works only when the owner presses it with Safari frontmost. |
| B. Keep-alive, MV3 non-persistent | ❌ (see above) |
| B'. Keep-alive, **MV2 `persistent:true`** background page | ✅ The WebSocket stayed open 4 min 43 s with no drops. Page age 283 s on query. |
| C. `tabs.captureVisibleTab` for an unfocused window | ✅ PNG, ~866 KB |
| D. Find a DOM element by class in AX (`AXDOMClassList` contains marker) + `AXPress` | ✅ found, `isTrusted:true` click |
| D'. `kAXWindowsAttribute` | ⚠️ It returned only a non-browser window (title "", no web area) while the browser window was on another Space. **Always scan with the private remote-token API and match the web area by URL.** Never trust a non-empty public list. |
| E. `Origin` of the extension's WebSocket | `safari-web-extension://<uuid>` (lowercase). **The UUID changed on every (re)load of the temporary extension** (3 different values). |

## Consequences for the plan

- Wake strategy: neither W1 (background shortcut) nor W2 (click once per session) works with MV3, because the background page dies after ~1 min. The only reliable channel found is an **MV2 persistent background page** holding the WebSocket. The owner decides (energy trade-off).
- Markers: classes work (`__sc_m_<ref>`); no temporary ids are needed.
- Capture: `captureVisibleTab` works for an unfocused window, so the Task 13 ScreenCaptureKit fallback is not needed for now.
- Auth: TOFU pinning of the extension origin breaks on every extension reload. Accept any `safari-web-extension://` origin instead. Web pages cannot forge it, and a local process can already do anything.
