import ApplicationServices

public protocol Actuator {
    func press(marker: String, pageURL: String) throws
    func isSafariFrontmost() -> Bool
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

    static func find(_ e: AXElement, marker: String, depth: Int) -> AXElement? {
        if depth > 60 { return nil }
        if let list = e.attr("AXDOMClassList") as? [String], list.contains(marker) { return e }
        for c in e.children {
            if let r = find(c, marker: marker, depth: depth + 1) { return r }
        }
        return nil
    }
}
