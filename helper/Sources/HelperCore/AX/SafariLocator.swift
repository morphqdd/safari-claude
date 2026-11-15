import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementCreateWithRemoteToken")
private func _AXUIElementCreateWithRemoteToken(_ data: CFData) -> Unmanaged<AXUIElement>?

public enum SafariLocator {
    public static func safariPid() -> pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first?.processIdentifier
    }

    /// Union of the public AXWindows list and a private remote-token scan, deduplicated.
    /// The public list may hold only a non-browser window (e.g. Settings) when the browser window is on another Space.
    public static func windows() -> [AXElement] {
        guard let pid = safariPid() else { return [] }
        var out = ((AXElement(AXUIElementCreateApplication(pid)).attr("AXWindows") as? [AXUIElement]) ?? [])
            .map(AXElement.init)
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        for id: UInt64 in 0..<3000 {
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: id) { Data($0) })
            guard let ref = _AXUIElementCreateWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            let el = AXElement(ref)
            guard (el.attr("AXRole") as? String) == "AXWindow" else { continue }
            if !out.contains(where: { $0.isSame(as: el) }) { out.append(el) }
        }
        return out
    }

    /// The AXWebArea whose AXURL absolute string equals `url`.
    public static func webArea(url: String) -> AXElement? {
        for w in windows() {
            if let a = findWebArea(w, url: url, depth: 0) { return a }
        }
        return nil
    }

    private static func findWebArea(_ e: AXElement, url: String, depth: Int) -> AXElement? {
        if depth > 60 { return nil }
        if (e.attr("AXRole") as? String) == "AXWebArea" {
            if let u = e.attr("AXURL") as? URL, u.absoluteString == url { return e }
            return nil // do not descend into non-matching web areas
        }
        for c in e.children {
            if let r = findWebArea(c, url: url, depth: depth + 1) { return r }
        }
        return nil
    }
}
