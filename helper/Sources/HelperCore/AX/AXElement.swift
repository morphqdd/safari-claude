import ApplicationServices

/// Thin wrapper over AXUIElement.
public struct AXElement {
    public let ref: AXUIElement

    public init(_ ref: AXUIElement) { self.ref = ref }

    public func attr(_ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(ref, name as CFString, &v) == .success ? v : nil
    }

    public var children: [AXElement] {
        ((attr("AXChildren") as? [AXUIElement]) ?? []).map(AXElement.init)
    }

    @discardableResult
    public func perform(_ action: String) -> AXError {
        AXUIElementPerformAction(ref, action as CFString)
    }

    public func isSame(as other: AXElement) -> Bool { CFEqual(ref, other.ref) }
}
