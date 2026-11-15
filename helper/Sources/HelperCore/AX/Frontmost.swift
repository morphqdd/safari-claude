import CoreGraphics

public enum Frontmost {
    /// Owner PID of the first on-screen layer-0 window. (NSWorkspace.frontmostApplication is stale without a run loop.)
    static func frontmostPID() -> pid_t? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let first = list.first(where: { ($0[kCGWindowLayer as String] as? Int) == 0 })
        else { return nil }
        return first[kCGWindowOwnerPID as String] as? Int32
    }

    static func isFrontmost(pid: pid_t) -> Bool { frontmostPID() == pid }

    public static func isSafari() -> Bool {
        guard let pid = SafariLocator.safariPid() else { return false }
        return isFrontmost(pid: pid)
    }
}
