import Testing
import Foundation
@testable import HelperCore

final class FakeActuator: Actuator, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [String] = []
    var frontmost = false
    var pressError: Error?
    func record(_ s: String) { lock.lock(); calls.append(s); lock.unlock() }
    func press(marker: String, pageURL: String) throws {
        record("press:\(marker):\(pageURL)")
        if let pressError { throw pressError }
    }
    func isSafariFrontmost() -> Bool { frontmost }
    func postText(_ text: String) throws { record("postText:\(text)") }
    func postCombo(_ combo: KeyCombo) throws { record("postCombo:\(combo.key)") }
}

/// Extension side of a link: answers each request by method name and records the methods.
final class ScriptedExtension: Connection, @unchecked Sendable {
    var origin: String? = nil
    var onText: ((String) -> Void)?
    var onClose: (() -> Void)?
    private let lock = NSLock()
    private var _methods: [String] = []
    var responder: (String, JSON) -> Result<JSON, RPCError> = { _, _ in .success(.object([:])) }
    weak var link: ExtensionLink?
    var hold: Set<String> = []
    var methods: [String] { lock.lock(); defer { lock.unlock() }; return _methods }
    func send(_ text: String) {
        guard case .req(let id, let method, let params)? = try? JSONDecoder().decode(Message.self, from: Data(text.utf8)) else { return }
        lock.lock(); _methods.append(method); lock.unlock()
        if hold.contains(method) { return }
        let r = responder(method, params)
        DispatchQueue.global().async {
            switch r {
            case .success(let j): self.link?.handleResponse(id: id, result: j, error: nil)
            case .failure(let e): self.link?.handleResponse(id: id, result: nil, error: e)
            }
        }
    }
    func close(code: UInt16) {}
}

private func obj(_ d: [String: JSON]) -> JSON { .object(d) }

private struct Rig {
    let link = ExtensionLink()
    let ext = ScriptedExtension()
    let actuator = FakeActuator()
    let runner: ToolRunner
    init(active: Bool = true, risky: Bool = false, windowFocused: Bool = true, focused: Bool = true,
         submitRisky: Bool = false, hold: Set<String> = [], extra: @escaping (String, JSON) -> Result<JSON, RPCError>? = { _, _ in nil }) {
        runner = ToolRunner(actuator: actuator, pollInterval: 0.01, findTimeout: 0.1)
        ext.link = link
        ext.hold = hold
        ext.responder = { method, params in
            if let r = extra(method, params) { return r }
            switch method {
            case "el.prepare": return .success(obj(["marker": .string("m1"), "risk": obj(["risky": .bool(risky)])]))
            case "tab.state": return .success(obj(["tabId": .number(1), "url": .string("https://a.test/"), "title": .string("A"), "activeInWindow": .bool(active), "windowFocused": .bool(windowFocused)]))
            case "el.focus": return .success(obj(["focused": .bool(focused)]))
            case "el.submitRisk": return .success(obj(["risky": .bool(submitRisky)]))
            case "el.value": return .success(obj(["value": .string("abc")]))
            case "el.domType": return .success(obj(["value": .string("abc")]))
            default: return .success(obj([:]))
            }
        }
        link.attach(ext)
    }
    func run(_ name: String, _ args: [String: JSON]) async throws -> String {
        let r = try await runner.call(name: name, arguments: .object(args), link: link)
        return r["content"].flatMap { if case .array(let a) = $0 { return a.first?["text"]?.string } else { return nil } } ?? ""
    }
}

@Suite(.serialized) struct ToolRunnerTests {
    @Test func clickUsesAXWhenTabActive() async throws {
        let rig = Rig()
        let t = try await rig.run("click", ["ref": .string("e1")])
        #expect(t == "clicked (trusted)")
        #expect(rig.actuator.calls == ["press:m1:https://a.test/"])
        #expect(!rig.ext.methods.contains("el.domClick"))
        #expect(rig.ext.methods.last == "el.release")
    }

    @Test func clickFallsBackToDomWhenAXNotFound() async throws {
        let rig = Rig()
        rig.actuator.pressError = RPCError.notFound("x")
        let t = try await rig.run("click", ["ref": .string("e1")])
        #expect(t == "clicked (dom)")
        #expect(rig.ext.methods.contains("el.domClick"))
    }

    @Test func clickFallsBackToDomOnInternalAXError() async throws {
        let rig = Rig()
        rig.actuator.pressError = RPCError.internal("Safari is not responding")
        #expect(try await rig.run("click", ["ref": .string("e1")]) == "clicked (dom)")
    }

    @Test func clickInBackgroundTabUsesDom() async throws {
        let rig = Rig(active: false)
        let t = try await rig.run("click", ["ref": .string("e1")])
        #expect(t == "clicked (dom)")
        #expect(rig.ext.methods.contains("el.domClick"))
        #expect(rig.actuator.calls.isEmpty)
    }

    @Test func riskyClickRequiresConfirmation() async throws {
        let rig = Rig(risky: true)
        do {
            _ = try await rig.run("click", ["ref": .string("e1")])
            Issue.record("expected error")
        } catch let e as RPCError {
            #expect(e.code == "risky_requires_confirmation")
        }
        #expect(rig.actuator.calls.isEmpty)
        #expect(!rig.ext.methods.contains("el.domClick"))
        #expect(rig.ext.methods.contains("el.release"))
    }

    @Test func confirmActionClickSkipsRisk() async throws {
        let rig = Rig(risky: true)
        let t = try await rig.run("confirm_action", ["kind": .string("click"), "ref": .string("e1")])
        #expect(t == "clicked (trusted)")
        #expect(rig.actuator.calls == ["press:m1:https://a.test/"])
    }

    @Test func confirmActionClickWithoutRefIsBadRequest() async {
        let rig = Rig()
        do { _ = try await rig.run("confirm_action", ["kind": .string("click")]); Issue.record("expected error") }
        catch let e as RPCError { #expect(e.code == "bad_request") } catch { Issue.record("unexpected error \(error)") }
    }

    @Test func confirmSiteAllows() async throws {
        let rig = Rig()
        #expect(try await rig.run("confirm_action", ["kind": .string("site"), "domain": .string("x.com")]) == "allowed x.com")
        #expect(rig.ext.methods.contains("site.allow"))
    }

    @Test func typeUsesDomWhenSafariFrontmost() async throws {
        let rig = Rig()
        rig.actuator.frontmost = true
        let t = try await rig.run("type", ["ref": .string("e1"), "text": .string("abc")])
        #expect(t == "typed (dom); value: \"abc\"")
        #expect(rig.ext.methods.contains("el.domType"))
        #expect(rig.actuator.calls.isEmpty)
    }

    @Test func typeUsesKeysWhenSafariBackground() async throws {
        let rig = Rig()
        rig.actuator.frontmost = false
        let t = try await rig.run("type", ["ref": .string("e1"), "text": .string("abc"), "submit": .bool(true)])
        #expect(t == "typed (trusted); value: \"abc\"")
        #expect(rig.actuator.calls == ["postText:abc", "postCombo:Enter"])
        #expect(!rig.ext.methods.contains("el.domType"))
        let m = rig.ext.methods
        #expect(m.firstIndex(of: "el.release")! < m.firstIndex(of: "el.value")!)
    }

    @Test func keyUsesDomOrTrusted() async throws {
        let a = Rig(active: false)
        #expect(try await a.run("key", ["combo": .string("Enter")]) == "pressed Enter (dom)")
        #expect(a.ext.methods.contains("el.domKey"))
        let b = Rig()
        #expect(try await b.run("key", ["combo": .string("Enter")]) == "pressed Enter (trusted)")
        #expect(b.actuator.calls == ["postCombo:Enter"])
    }

    @Test func screenshotStripsDataUrlPrefix() async throws {
        let rig = Rig(extra: { m, _ in m == "tab.screenshot" ? .success(obj(["dataUrl": .string("data:image/png;base64,QUJD")])) : nil })
        let r = try await rig.runner.call(name: "screenshot", arguments: .object([:]), link: rig.link)
        #expect(r["content"] == .array([obj(["type": .string("image"), "data": .string("QUJD"), "mimeType": .string("image/png")])]))
    }

    @Test func tabsListMarksAgentTab() async throws {
        let rig = Rig(extra: { m, _ in
            m == "tabs.list" ? .success(obj(["tabs": .array([
                obj(["tabId": .number(1), "url": .string("u1"), "title": .string("T1"), "isAgent": .bool(true)]),
                obj(["tabId": .number(2), "url": .string("u2"), "title": .string("T2"), "isAgent": .bool(false)])])])) : nil })
        #expect(try await rig.run("tabs_list", [:]) == "1 * u1 — T1\n2   u2 — T2")
    }

    @Test func findFormatsMatchesAndNone() async throws {
        let rig = Rig(extra: { m, _ in
            m == "page.find" ? .success(obj(["matches": .array([obj(["ref": .string("e3"), "role": .string("button"), "name": .string("Go")])])])) : nil })
        #expect(try await rig.run("find", ["query": .string("go")]) == "[ref=e3] button \"Go\"")
        let none = Rig(extra: { m, _ in m == "page.find" ? .success(obj(["matches": .array([])])) : nil })
        #expect(try await none.run("find", ["query": .string("go")]) == "no matches")
    }

    @Test func waitForTimesOut() async {
        let rig = Rig(extra: { m, _ in m == "page.find" ? .success(obj(["matches": .array([])])) : nil })
        do { _ = try await rig.run("wait", ["for": .string("x")]); Issue.record("expected error") }
        catch let e as RPCError { #expect(e.code == "timeout"); #expect(e.message == "\"x\" not found within 10 s") } catch { Issue.record("unexpected error \(error)") }
    }

    @Test func waitMsReportsClamped() async throws {
        let rig = Rig()
        #expect(try await rig.run("wait", ["ms": .number(5)]) == "waited 5 ms")
    }

    @Test func missingArgsAndUnknownTool() async {
        let rig = Rig()
        for (name, args) in [("click", [String: JSON]()), ("type", ["ref": .string("e")]), ("navigate", [:]), ("nope", [:])] {
            do { _ = try await rig.run(name, args); Issue.record("expected error for \(name)") }
            catch let e as RPCError { #expect(e.code == "bad_request") } catch { Issue.record("unexpected error \(error)") }
        }
    }

    @Test func overlayFailureIsIgnored() async throws {
        let rig = Rig(extra: { m, _ in m == "overlay.status" ? .failure(RPCError.internal("x")) : nil })
        #expect(try await rig.run("click", ["ref": .string("e1")]) == "clicked (trusted)")
    }

    @Test func cancellationStopsDrivingAndReleases() async throws {
        let rig = Rig(hold: ["tab.state"])
        let task = Task { try await rig.run("click", ["ref": .string("e1")]) }
        for _ in 0..<200 where !rig.ext.methods.contains("tab.state") { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel()
        do { _ = try await task.value; Issue.record("expected error") }
        catch let e as RPCError { #expect(e.code == "cancelled") } catch { Issue.record("unexpected error \(error)") }
        #expect(rig.actuator.calls.isEmpty)
        #expect(!rig.ext.methods.contains("el.domClick"))
        #expect(rig.ext.methods.contains("el.release"))
    }

    @Test func cancelDuringPrepareReleases() async throws {
        let rig = Rig(hold: ["el.prepare"])
        let task = Task { try await rig.run("click", ["ref": .string("e1")]) }
        for _ in 0..<200 where !rig.ext.methods.contains("el.prepare") { try await Task.sleep(nanoseconds: 10_000_000) }
        task.cancel()
        _ = try? await task.value
        #expect(rig.ext.methods.contains("el.release"))
    }

    @Test func releaseFailureDoesNotFailClick() async throws {
        let rig = Rig(extra: { m, _ in m == "el.release" ? .failure(RPCError.internal("gone")) : nil })
        #expect(try await rig.run("click", ["ref": .string("e1")]) == "clicked (trusted)")
    }

    @Test func valueFailureAfterTypeIsPageChanged() async throws {
        let rig = Rig(extra: { m, _ in m == "el.value" ? .failure(RPCError.notFound("gone")) : nil })
        let t = try await rig.run("type", ["ref": .string("e1"), "text": .string("abc")])
        #expect(t == "typed (trusted); value: (page changed)")
    }

    @Test func unfocusedElementFallsBackToDomType() async throws {
        let rig = Rig(focused: false)
        let t = try await rig.run("type", ["ref": .string("e1"), "text": .string("abc")])
        #expect(t.hasPrefix("typed (dom)"))
        #expect(rig.actuator.calls.isEmpty)
    }

    @Test func keyUsesDomWhenWindowNotFocused() async throws {
        let rig = Rig(windowFocused: false)
        #expect(try await rig.run("key", ["combo": .string("Tab")]) == "pressed Tab (dom)")
        #expect(rig.actuator.calls.isEmpty)
    }

    @Test func keyUsesDomWhenSafariFrontmost() async throws {
        let rig = Rig()
        rig.actuator.frontmost = true
        #expect(try await rig.run("key", ["combo": .string("Tab")]) == "pressed Tab (dom)")
        #expect(rig.ext.methods.contains("el.domKey"))
    }

    @Test func riskySubmitViaTypeRequiresConfirmation() async {
        let rig = Rig(submitRisky: true)
        do { _ = try await rig.run("type", ["ref": .string("e1"), "text": .string("abc"), "submit": .bool(true)]); Issue.record("expected error") }
        catch let e as RPCError { #expect(e.code == "risky_requires_confirmation") } catch { Issue.record("unexpected error \(error)") }
        #expect(rig.actuator.calls.isEmpty)
        #expect(!rig.ext.methods.contains("el.domType"))
    }

    @Test func confirmTypeSkipsSubmitRisk() async throws {
        let rig = Rig(risky: true, submitRisky: true)
        let t = try await rig.run("confirm_action", ["kind": .string("type"), "ref": .string("e1"), "text": .string("abc"), "submit": .bool(true)])
        #expect(t.hasPrefix("typed (trusted)"))
        #expect(rig.actuator.calls == ["postText:abc", "postCombo:Enter"])
    }

    @Test func riskyEnterViaKeyRequiresConfirmation() async {
        let rig = Rig(submitRisky: true)
        do { _ = try await rig.run("key", ["combo": .string("Enter")]); Issue.record("expected error") }
        catch let e as RPCError { #expect(e.code == "risky_requires_confirmation") } catch { Issue.record("unexpected error \(error)") }
        #expect(rig.actuator.calls.isEmpty)
        #expect(!rig.ext.methods.contains("el.domKey"))
    }

    @Test func confirmKeyPresses() async throws {
        let rig = Rig(submitRisky: true)
        #expect(try await rig.run("confirm_action", ["kind": .string("key"), "combo": .string("Enter")]) == "pressed Enter (trusted)")
        #expect(rig.actuator.calls == ["postCombo:Enter"])
    }
}
