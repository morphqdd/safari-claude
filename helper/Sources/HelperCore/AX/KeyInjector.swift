import CoreGraphics
import Foundation

public struct KeyCombo: Equatable {
    public var key: String
    public var modifiers: CGEventFlags

    public init(key: String, modifiers: CGEventFlags = []) {
        self.key = key
        self.modifiers = modifiers
    }

    static let named: [String: String] = [
        "enter": "Enter", "tab": "Tab", "escape": "Escape", "backspace": "Backspace", "delete": "Delete",
        "arrowup": "ArrowUp", "arrowdown": "ArrowDown", "arrowleft": "ArrowLeft", "arrowright": "ArrowRight",
        "home": "Home", "end": "End", "pageup": "PageUp", "pagedown": "PageDown", "space": "Space",
    ]
    static let mods: [String: CGEventFlags] = [
        "cmd": .maskCommand, "shift": .maskShift, "alt": .maskAlternate, "ctrl": .maskControl,
    ]

    public static func parse(_ s: String) throws -> KeyCombo {
        var flags: CGEventFlags = []
        var rest = Substring(s)
        while let plus = rest.firstIndex(of: "+"), plus != rest.startIndex,
              let m = mods[rest[..<plus].lowercased()] {
            flags.insert(m)
            rest = rest[rest.index(after: plus)...]
        }
        if let n = named[rest.lowercased()] { return KeyCombo(key: n, modifiers: flags) }
        if rest.count == 1 { return KeyCombo(key: String(rest), modifiers: flags) }
        throw RPCError.badRequest("unknown key combo: \(s)")
    }
}

public enum KeyInjector {
    /// One chunk of UTF-16 code units per grapheme cluster.
    public static func chunks(_ text: String) -> [[UInt16]] {
        text.map { Array(String($0).utf16) }
    }

    static let ansi: [String: CGKeyCode] = {
        var t: [String: CGKeyCode] = [:]
        let letters: [(String, CGKeyCode)] = [
            ("a", 0), ("s", 1), ("d", 2), ("f", 3), ("h", 4), ("g", 5), ("z", 6), ("x", 7), ("c", 8), ("v", 9),
            ("b", 11), ("q", 12), ("w", 13), ("e", 14), ("r", 15), ("y", 16), ("t", 17),
            ("1", 18), ("2", 19), ("3", 20), ("4", 21), ("6", 22), ("5", 23), ("=", 24), ("9", 25), ("7", 26),
            ("-", 27), ("8", 28), ("0", 29), ("]", 30), ("o", 31), ("u", 32), ("[", 33), ("i", 34), ("p", 35),
            ("l", 37), ("j", 38), ("'", 39), ("k", 40), (";", 41), ("\\", 42), (",", 43), ("/", 44),
            ("n", 45), ("m", 46), (".", 47), ("`", 50),
            ("Enter", 36), ("Tab", 48), ("Space", 49), (" ", 49), ("Backspace", 51), ("Escape", 53),
            ("Delete", 117), ("Home", 115), ("End", 119), ("PageUp", 116), ("PageDown", 121),
            ("ArrowLeft", 123), ("ArrowRight", 124), ("ArrowDown", 125), ("ArrowUp", 126),
        ]
        for (k, v) in letters { t[k] = v }
        return t
    }()

    /// ANSI (kVK_*) key code; uppercase ASCII letters map to their lowercase key.
    public static func virtualKey(for key: String) -> CGKeyCode? {
        if let v = ansi[key] { return v }
        return ansi[key.lowercased()]
    }

    /// Key code and optional Unicode string for one grapheme chunk. Newlines and tabs become Enter/Tab keys.
    static func keyEvent(for chunk: [UInt16]) -> (key: CGKeyCode, unicode: [UInt16]?) {
        let s = String(decoding: chunk, as: UTF16.self)
        switch s {
        case "\n", "\r", "\r\n": return (36, nil)
        case "\t": return (48, nil)
        default:
            if s.unicodeScalars.count == 1, let u = s.unicodeScalars.first, u.isASCII {
                return (virtualKey(for: s) ?? 0, chunk)
            }
            return (0, chunk)
        }
    }

    static let frontmostMessage = "Safari стал активным — ввод остановлен"
    static let cancelledMessage = "Пользователь нажал «Стоп»"

    /// Emits one keyDown/keyUp pair. `isFrontmost` is checked before the keyDown only: once a keyDown
    /// is posted its keyUp is always posted too, so no key is left stuck down.
    static func pair(isFrontmost: () -> Bool, emit: (_ down: Bool) throws -> Void) throws {
        if isFrontmost() { throw RPCError.cancelled(frontmostMessage) }
        try emit(true)
        try emit(false)
    }

    /// Feeds `text` chunk by chunk, checking `isCancelled` (Stop) before each chunk.
    static func typeChunks(_ text: String, isCancelled: () -> Bool, post: ([UInt16]) throws -> Void) throws {
        for chunk in chunks(text) {
            if isCancelled() { throw RPCError.cancelled(cancelledMessage) }
            try post(chunk)
        }
    }

    /// Posts one keyDown/keyUp pair to `pid`.
    static func post(pid: pid_t, vk: CGKeyCode, units: [UInt16]?, flags: CGEventFlags,
                     isFrontmost: () -> Bool) throws {
        guard let downEv = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: true),
              let upEv = CGEvent(keyboardEventSource: nil, virtualKey: vk, keyDown: false) else {
            throw RPCError.internal("CGEvent creation failed")
        }
        try pair(isFrontmost: isFrontmost) { down in
            let e = down ? downEv : upEv
            if let units { e.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units) }
            e.flags = flags
            e.postToPid(pid)
        }
    }
}

extension AXActuator {
    public func postText(_ text: String) throws {
        guard let pid = SafariLocator.safariPid() else { throw RPCError.notFound("Safari is not running") }
        try KeyInjector.typeChunks(text, isCancelled: { Task.isCancelled }) { chunk in
            let (vk, units) = KeyInjector.keyEvent(for: chunk)
            let s = String(decoding: chunk, as: UTF16.self)
            let upper = units != nil && s.unicodeScalars.count == 1 && s.unicodeScalars.first!.isASCII
                && s.rangeOfCharacter(from: .uppercaseLetters) != nil
            try KeyInjector.post(pid: pid, vk: vk, units: units, flags: upper ? .maskShift : [],
                                 isFrontmost: isSafariFrontmost)
            Thread.sleep(forTimeInterval: 0.015)
        }
    }

    public func postCombo(_ combo: KeyCombo) throws {
        guard let pid = SafariLocator.safariPid() else { throw RPCError.notFound("Safari is not running") }
        guard let vk = KeyInjector.virtualKey(for: combo.key) else {
            throw RPCError.badRequest("no key code for \(combo.key)")
        }
        let units = combo.key.count == 1 ? Array(combo.key.utf16) : nil
        try KeyInjector.post(pid: pid, vk: vk, units: units, flags: combo.modifiers,
                             isFrontmost: isSafariFrontmost)
    }
}
