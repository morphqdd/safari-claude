import Foundation

/// Orchestrates MCP tools: asks the Safari extension to prepare/animate/mark elements and decides
/// whether to act through real Accessibility input (`Actuator`) or DOM events in the extension.
public final class ToolRunner: ToolHandling {
    private let actuator: Actuator
    private let pollInterval: TimeInterval
    private let findTimeout: TimeInterval
    private let pressRetryDelay: TimeInterval

    public init(actuator: Actuator) {
        self.actuator = actuator
        self.pollInterval = 0.5
        self.findTimeout = 10
        self.pressRetryDelay = 0.15
    }

    init(actuator: Actuator, pollInterval: TimeInterval, findTimeout: TimeInterval, pressRetryDelay: TimeInterval = 0.001) {
        self.actuator = actuator
        self.pollInterval = pollInterval
        self.findTimeout = findTimeout
        self.pressRetryDelay = pressRetryDelay
    }

    public func call(name: String, arguments: JSON, link: ExtensionLink) async throws -> JSON {
        let run = Run(actuator: actuator, link: link, args: arguments, tool: name,
                      pollInterval: pollInterval, findTimeout: findTimeout, pressRetryDelay: pressRetryDelay)
        switch name {
        case "tabs_list": return try await run.tabsList()
        case "tab_create": return try await run.tabCreate()
        case "tab_select": return try await run.tabSelect()
        case "navigate": return try await run.navigate()
        case "read_page": return try await run.readPage()
        case "find": return try await run.find()
        case "get_text": return try await run.getText()
        case "click": return try await run.click(checkRisk: true)
        case "type": return try await run.type(confirmed: false)
        case "key": return try await run.key(confirmed: false)
        case "scroll": return try await run.scroll()
        case "screenshot": return try await run.screenshot()
        case "wait": return try await run.wait()
        case "confirm_action": return try await run.confirm()
        default: throw RPCError.badRequest("unknown tool \(name)")
        }
    }
}

private struct Run {
    let actuator: Actuator
    let link: ExtensionLink
    let args: JSON
    let tool: String
    let pollInterval: TimeInterval
    let findTimeout: TimeInterval
    let pressRetryDelay: TimeInterval

    /// Best-effort diagnostics to stderr (SafariClaude.log): path decisions only, no page content.
    static func log(_ s: String) {
        FileHandle.standardError.write(Data("tool: \(s)\n".utf8))
    }

    // MARK: helpers

    static func text(_ s: String) -> JSON {
        .object(["content": .array([.object(["type": .string("text"), "text": .string(s)])]), "isError": .bool(false)])
    }

    func checkCancelled() throws {
        if Task.isCancelled { throw RPCError.cancelled("Пользователь нажал «Стоп»") }
    }

    /// Extension-side page loads wait up to 30 s, so navigation requests get a longer link timeout.
    static let navigationTimeout: TimeInterval = 35

    func ext(_ method: String, _ params: [String: JSON] = [:], timeout: TimeInterval? = nil) async throws -> JSON {
        try checkCancelled()
        let r: JSON
        do { r = try await link.request(method, .object(params), timeout: timeout) }
        catch {
            if Task.isCancelled { throw RPCError.cancelled("Пользователь нажал «Стоп»") }
            throw error
        }
        try checkCancelled()
        return r
    }

    /// Best-effort overlay text, sent without waiting: a throttled background tab may never answer.
    func status(_ text: String) async throws {
        try checkCancelled()
        let link = self.link
        Task.detached { _ = try? await link.request("overlay.status", .object(["text": .string(text)]), timeout: 5) }
    }

    func str(_ key: String, required: Bool = true) throws -> String? {
        if let v = args[key]?.string, !v.isEmpty { return v }
        if args[key] != nil, args[key] != .null, args[key]?.string == nil {
            throw RPCError.badRequest("\(tool): \(key) must be a string")
        }
        if required { throw RPCError.badRequest("\(tool): missing \(key)") }
        return nil
    }
    func req(_ key: String) throws -> String { try str(key)! }

    func resultText(_ r: JSON, _ key: String) -> String { r[key]?.string ?? "" }

    /// Only http:, https: and about:blank may be opened.
    static func checkURL(_ u: String, tool: String) throws {
        if u == "about:blank" { return }
        let scheme = URL(string: u)?.scheme?.lowercased()
        if scheme != "http" && scheme != "https" {
            throw RPCError.badRequest("\(tool): only http, https and about:blank URLs are allowed")
        }
    }

    // MARK: simple 1:1 tools

    func tabsList() async throws -> JSON {
        let r = try await ext("tabs.list")
        guard case .array(let tabs)? = r["tabs"] else { return Self.text("") }
        let lines = tabs.map { t -> String in
            let id = t["tabId"]?.int.map(String.init) ?? "?"
            let mark = t["isAgent"]?.bool == true ? "*" : " "
            return "\(id) \(mark) \(resultText(t, "url")) — \(resultText(t, "title"))"
        }
        return Self.text(lines.joined(separator: "\n"))
    }

    func tabCreate() async throws -> JSON {
        var p: [String: JSON] = [:]
        if let u = try str("url", required: false) {
            try Self.checkURL(u, tool: tool)
            p["url"] = .string(u)
        }
        let r = try await ext("tabs.create", p, timeout: Self.navigationTimeout)
        return Self.text("agent tab \(r["tabId"]?.int ?? 0)")
    }

    func tabSelect() async throws -> JSON {
        guard let id = args["tabId"]?.int else { throw RPCError.badRequest("tab_select: missing tabId") }
        _ = try await ext("tabs.select", ["tabId": .number(Double(id))])
        return Self.text("agent tab \(id)")
    }

    func navigate() async throws -> JSON {
        var p: [String: JSON] = [:]
        if let u = try str("url", required: false) {
            try Self.checkURL(u, tool: tool)
            p["url"] = .string(u)
        } else if let a = try str("action", required: false) { p["action"] = .string(a) }
        else { throw RPCError.badRequest("navigate: missing url or action") }
        try await status("Открываю \(p["url"]?.string ?? p["action"]?.string ?? "")")
        let r = try await ext("navigate", p, timeout: Self.navigationTimeout)
        return Self.text("\(resultText(r, "title")) — \(resultText(r, "url"))")
    }

    func readPage() async throws -> JSON {
        var p: [String: JSON] = [:]
        if let f = try str("filter", required: false) { p["filter"] = .string(f) }
        try await status("Читаю страницу")
        let r = try await ext("page.snapshot", p)
        return Self.text(resultText(r, "text"))
    }

    func findLines(_ r: JSON) -> String {
        guard case .array(let ms)? = r["matches"], !ms.isEmpty else { return "no matches" }
        return ms.map { "[ref=\(resultText($0, "ref"))] \(resultText($0, "role")) \"\(resultText($0, "name"))\"" }
            .joined(separator: "\n")
    }

    func find() async throws -> JSON {
        let q = try req("query")
        try await status("Ищу «\(q)»")
        let r = try await ext("page.find", ["query": .string(q)])
        return Self.text(findLines(r))
    }

    func getText() async throws -> JSON {
        var p: [String: JSON] = [:]
        if let ref = try str("ref", required: false) { p["ref"] = .string(ref) }
        let r = try await ext("page.text", p)
        return Self.text(resultText(r, "text"))
    }

    func scroll() async throws -> JSON {
        var p: [String: JSON] = [:]
        if let ref = try str("ref", required: false) { p["ref"] = .string(ref) }
        if let d = try str("direction", required: false) { p["direction"] = .string(d) }
        if let a = args["amount"]?.int { p["amount"] = .number(Double(a)) }
        try await status("Прокручиваю")
        _ = try await ext("page.scroll", p)
        return Self.text("scrolled")
    }

    func screenshot() async throws -> JSON {
        // Reject a background tab before the overlay status, which can stall on throttled background tabs.
        let state = try await ext("tab.state")
        if state["activeInWindow"]?.bool != true {
            throw RPCError.backgroundTab("Вкладка агента в фоне: скриншот невозможен")
        }
        try await status("Делаю снимок")
        let r = try await ext("tab.screenshot")
        var data = resultText(r, "dataUrl")
        if let range = data.range(of: "base64,") { data = String(data[range.upperBound...]) }
        return .object([
            "content": .array([.object(["type": .string("image"), "data": .string(data), "mimeType": .string("image/png")])]),
            "isError": .bool(false),
        ])
    }

    func wait() async throws -> JSON {
        if let cond = try str("for", required: false) {
            try await status("Жду «\(cond)»")
            let deadline = Date().addingTimeInterval(findTimeout)
            while true {
                let r = try await ext("page.find", ["query": .string(cond)])
                if case .array(let ms)? = r["matches"], !ms.isEmpty { return Self.text("found \"\(cond)\"") }
                if Date() >= deadline { throw RPCError.timeout("\"\(cond)\" not found within 10 s") }
                try await sleep(pollInterval)
            }
        }
        guard let ms = args["ms"]?.int else { throw RPCError.badRequest("wait: missing ms or for") }
        let clamped = min(max(ms, 0), 30000)
        try await status("Жду")
        try await sleep(Double(clamped) / 1000)
        return Self.text("waited \(clamped) ms")
    }

    func sleep(_ seconds: TimeInterval) async throws {
        do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
        catch { throw RPCError.cancelled("Пользователь нажал «Стоп»") }
        try checkCancelled()
    }

    func confirm() async throws -> JSON {
        switch try req("kind") {
        case "site":
            let d = try req("domain")
            _ = try await ext("site.allow", ["domain": .string(d)])
            return Self.text("allowed \(d)")
        case "click":
            _ = try req("ref")
            return try await click(checkRisk: false)
        case "type":
            _ = try req("ref"); _ = try req("text")
            return try await type(confirmed: true)
        case "key":
            _ = try req("combo")
            return try await key(confirmed: true)
        default:
            throw RPCError.badRequest("confirm_action: unknown kind")
        }
    }

    // MARK: element actions

    /// Best-effort el.release, sent from a context that Stop (task cancellation) cannot cancel.
    func release(_ ref: String) async {
        let link = self.link
        await Task.detached {
            _ = try? await link.request("el.release", .object(["ref": .string(ref)]))
        }.value
    }

    /// Runs `body` between el.prepare and el.release. Release is always sent (also on error or Stop)
    /// and its failure never fails the action.
    func withElement<T>(_ ref: String, action: String, checkRisk: Bool,
                        _ body: (JSON) async throws -> T) async throws -> T {
        let result: T
        do {
            let prep = try await ext("el.prepare", ["ref": .string(ref), "action": .string(action)])
            if checkRisk, prep["risk"]?["risky"]?.bool == true {
                let kind = prep["risk"]?["kind"]?.string.map { " (\($0))" } ?? ""
                throw RPCError.riskyRequiresConfirmation("risky action\(kind): use confirm_action kind=\(action)")
            }
            result = try await body(prep)
        } catch {
            await release(ref)
            throw error
        }
        await release(ref)
        return result
    }

    /// Throws risky_requires_confirmation when pressing Enter would submit a risky form.
    func checkSubmitRisk(ref: String?, kind: String) async throws {
        var p: [String: JSON] = [:]
        if let ref { p["ref"] = .string(ref) }
        let r = try await ext("el.submitRisk", p)
        if r["risky"]?.bool == true {
            throw RPCError.riskyRequiresConfirmation("submitting this form needs confirmation: use confirm_action kind=\(kind)")
        }
    }

    /// WebKit updates the AX tree asynchronously after the extension marks the element, so a missing
    /// web area/marker is retried (6 tries, `pressRetryDelay` apart) before giving up. Sleeps only here.
    static let pressAttempts = 6

    func pressWithRetry(marker: String, pageURL: String) async throws {
        for attempt in 1...Self.pressAttempts {
            try checkCancelled()
            do {
                try actuator.press(marker: marker, pageURL: pageURL)
                return
            } catch let e as RPCError where e.code == "not_found" {
                if attempt == Self.pressAttempts { throw e }
                try await Task.sleep(nanoseconds: UInt64(pressRetryDelay * 1_000_000_000))
            }
        }
    }

    func click(checkRisk: Bool) async throws -> JSON {
        let ref = try req("ref")
        try await status("Нажимаю \(ref)")
        let trusted = try await withElement(ref, action: "click", checkRisk: checkRisk) { prep -> Bool in
            let state = try await ext("tab.state")
            if state["activeInWindow"]?.bool == true, let marker = prep["marker"]?.string {
                try checkCancelled()
                do {
                    try await pressWithRetry(marker: marker, pageURL: resultText(state, "url"))
                    Self.log("click \(ref): trusted AXPress")
                    return true
                } catch let e as RPCError where e.code == "not_found" {
                    // The element was not reachable through AX, so nothing was pressed: use DOM events.
                    Self.log("click \(ref): DOM fallback (AX \(e.code) after \(Self.pressAttempts) tries)")
                } catch let e as RPCError where e.code == "cancelled" {
                    throw e
                } catch is CancellationError {
                    throw RPCError.cancelled("Пользователь нажал «Стоп»")
                } catch {
                    // The press may have happened; a DOM retry could click twice.
                    let detail = (error as? RPCError)?.message ?? "\(error)"
                    throw RPCError.internal("click may or may not have happened: \(detail); check the page with read_page before retrying")
                }
            } else {
                Self.log("click \(ref): DOM (tab not active in window or no marker)")
            }
            _ = try await ext("el.domClick", ["ref": .string(ref)])
            return false
        }
        return Self.text("clicked (\(trusted ? "trusted" : "dom"))")
    }

    /// Trusted keyboard input only when the tab is active in a focused window, Safari is not frontmost,
    /// and Safari's keyboard focus is inside the agent tab's web content (not the address bar etc.).
    func useKeys() async throws -> Bool {
        let state = try await ext("tab.state")
        let active = state["activeInWindow"]?.bool == true
        let focused = state["windowFocused"]?.bool == true
        guard active, focused, !actuator.isSafariFrontmost() else {
            Self.log("keys: DOM (activeInWindow=\(active) windowFocused=\(focused) safariFrontmost=\(actuator.isSafariFrontmost()))")
            return false
        }
        try checkCancelled()
        let webFocus = actuator.webContentHasFocus(pageURL: resultText(state, "url"))
        Self.log("keys: \(webFocus ? "trusted" : "DOM (keyboard focus not in page web area)")")
        return webFocus
    }

    /// Cmd/Ctrl combos other than Cmd+A/C/V/X/Z could reach Safari's own UI (Cmd+W, Cmd+Q, Cmd+L...),
    /// so they are never posted as real keystrokes.
    static func trustedComboAllowed(_ c: KeyCombo) -> Bool {
        if c.modifiers.contains(.maskControl) { return false }
        if !c.modifiers.contains(.maskCommand) { return true }
        return c.modifiers == .maskCommand && ["a", "c", "v", "x", "z"].contains(c.key.lowercased())
    }

    func type(confirmed: Bool) async throws -> JSON {
        let ref = try req("ref")
        guard let text = args["text"]?.string else { throw RPCError.badRequest("type: missing text") }
        let submit = args["submit"]?.bool == true
        let enter = try KeyCombo.parse("Enter")
        // A newline in the text becomes a real Return on the trusted path, so it is gated like submit.
        let newline = text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
        if (submit || newline) && !confirmed { try await checkSubmitRisk(ref: ref, kind: "type") }
        try await status("Ввожу текст в \(ref)")
        var trusted = false
        try await withElement(ref, action: "type", checkRisk: !confirmed) { _ -> Void in
            let focus = try await ext("el.focus", ["ref": .string(ref)])
            trusted = try await useKeys() && focus["focused"]?.bool == true
            if trusted {
                try checkCancelled()
                try actuator.postText(text)
            } else {
                _ = try await ext("el.domType", ["ref": .string(ref), "text": .string(text)])
            }
            if submit {
                if trusted {
                    try checkCancelled()
                    try actuator.postCombo(enter)
                } else { _ = try await ext("el.domKey", ["combo": .string("Enter")]) }
            }
        }
        // The page may be gone after a submit; the action already happened, so this is best-effort.
        let value = (try? await link.request("el.value", .object(["ref": .string(ref)])))
            .flatMap { $0["value"]?.string }
        let shown = value.map { "\"\($0)\"" } ?? "(page changed)"
        return Self.text("typed (\(trusted ? "trusted" : "dom")); value: \(shown)")
    }

    func key(confirmed: Bool) async throws -> JSON {
        let combo = try req("combo")
        let parsed = try KeyCombo.parse(combo)
        _ = try await ext("site.check")
        // Enter submits forms and Space activates a focused button: both are gated.
        if ["Enter", "Space", " "].contains(parsed.key) && !confirmed {
            try await checkSubmitRisk(ref: nil, kind: "key")
        }
        try await status("Нажимаю \(combo)")
        var trusted = false
        if Self.trustedComboAllowed(parsed) { trusted = try await useKeys() }
        if trusted {
            try checkCancelled()
            try actuator.postCombo(parsed)
        } else { _ = try await ext("el.domKey", ["combo": .string(combo)]) }
        return Self.text("pressed \(combo) (\(trusted ? "trusted" : "dom"))")
    }
}
