import ApplicationServices

public protocol Actuator {
    func press(marker: String, pageURL: String) throws
    func isSafariFrontmost() -> Bool
    func postText(_ text: String) throws
    func postCombo(_ combo: KeyCombo) throws
    /// True when Safari's focused UI element is inside the AXWebArea showing `pageURL`. Read-only.
    func webContentHasFocus(pageURL: String) -> Bool
}

public final class AXActuator: Actuator {
    public init() {}

    public func isSafariFrontmost() -> Bool { Frontmost.isSafari() }

    public func press(marker: String, pageURL: String) throws {
        guard let area = try SafariLocator.webArea(url: pageURL) else {
            throw RPCError.notFound("no web area for \(pageURL)")
        }
        guard let el = Self.find(area, marker: marker, depth: 0) else {
            throw RPCError.notFound("no element with marker \(marker)")
        }
        let err = el.perform(kAXPressAction as String)
        if err != .success { throw RPCError.internal("AXPress failed: \(err.rawValue)") }
    }

    /// Reads AXFocusedUIElement of the Safari app element and walks AXParent up to the agent tab's
    /// web area. Read-only attribute access; never sets focus. Any failure means "no".
    public func webContentHasFocus(pageURL: String) -> Bool {
        guard let pid = SafariLocator.safariPid(),
              let area = try? SafariLocator.webArea(url: pageURL) else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, SafariLocator.messagingTimeout)
        guard let focused = AXElement(app).attr("AXFocusedUIElement"),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return false }
        var cur: AXElement? = AXElement(focused as! AXUIElement)
        for _ in 0..<80 {
            guard let e = cur else { return false }
            if e.isSame(as: area) { return true }
            guard let parent = e.attr("AXParent"), CFGetTypeID(parent) == AXUIElementGetTypeID() else { return false }
            cur = AXElement(parent as! AXUIElement)
        }
        return false
    }

    static func find(_ e: AXElement, marker: String, depth: Int) -> AXElement? {
        if depth > 60 { return nil }
        if let list = e.attr("AXDOMClassList") as? [String], list.contains(marker) { return e }
        for c in e.children {
            if let r = find(c, marker: marker, depth: depth + 1) { return r }
        }
        return nil
    }
}
