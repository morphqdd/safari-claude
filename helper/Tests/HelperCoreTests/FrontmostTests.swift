import Foundation
import CoreGraphics
import Testing
@testable import HelperCore

@Suite struct FrontmostTests {
    @Test func frontmostPIDMatchesIndependentWalk() {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as! [[String: Any]]
        var expected: Int32?
        for w in list {
            if (w["kCGWindowLayer"] as? NSNumber)?.intValue == 0 {
                expected = (w["kCGWindowOwnerPID"] as? NSNumber)?.int32Value
                break
            }
        }
        let pid = Frontmost.frontmostPID()
        // A headless CI runner has no on-screen windows; then both must be nil.
        #expect(pid == expected)
        if let pid { #expect(Frontmost.isFrontmost(pid: pid)) }
    }
}
