import CoreGraphics

public enum Frontmost {
    /// The first on-screen layer-0 window belongs to Safari. (NSWorkspace.frontmostApplication is stale without a run loop.)
    public static func isSafari() -> Bool {
        guard let pid = SafariLocator.safariPid(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return false }
        guard let first = list.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 }) else { return false }
        return (first[kCGWindowOwnerPID as String] as? Int32) == pid
    }
}
