// Spike probe: `wake` posts Ctrl+Shift+Y to Safari; `class <marker>` finds and presses an element by AXDOMClassList.
import AppKit

@_silgen_name("_AXUIElementCreateWithRemoteToken")
func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

func attr(_ e: AXUIElement, _ n: String) -> AnyObject? {
  var v: AnyObject?
  return AXUIElementCopyAttributeValue(e, n as CFString, &v) == .success ? v : nil
}

let pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first!.processIdentifier

func windows() -> [AXUIElement] {
  let pub = (attr(AXUIElementCreateApplication(pid), "AXWindows") as? [AXUIElement]) ?? []
  _ = pub // public list may hold only non-browser windows (e.g. Settings); always scan
  var out: [AXUIElement] = []
  var token = Data(count: 20)
  token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
  token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
  for id: UInt64 in 0..<3000 {
    token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
    if let el = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue(),
       (attr(el, "AXRole") as? String) == "AXWindow" { out.append(el) }
  }
  return out
}

func findByClass(_ e: AXUIElement, _ cls: String, _ d: Int = 0) -> AXUIElement? {
  if d > 60 { return nil }
  if let list = attr(e, "AXDOMClassList") as? [String], list.contains(cls) { return e }
  for c in (attr(e, "AXChildren") as? [AXUIElement]) ?? [] { if let r = findByClass(c, cls, d + 1) { return r } }
  return nil
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "wake":
  let flags: CGEventFlags = [.maskControl, .maskShift]
  for down in [true, false] {
    let ev = CGEvent(keyboardEventSource: nil, virtualKey: 16 /* kVK_ANSI_Y */, keyDown: down)!
    ev.flags = flags
    ev.postToPid(pid)
  }
  print("posted Ctrl+Shift+Y to \(pid)")
case "class":
  let ws = windows()
  print("windows:", ws.count)
  for w in ws {
    if let el = findByClass(w, args[2]) {
      print("found in window '\(attr(w, "AXTitle") as? String ?? "")'; AXPress:",
            AXUIElementPerformAction(el, kAXPressAction as CFString).rawValue)
      exit(0)
    }
  }
  print("not found")
  exit(2)
default:
  print("usage: probe wake | probe class <marker>")
}
