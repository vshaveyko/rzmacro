import CoreGraphics
import Foundation

struct ConfigError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Key names usable in `keys:` chords. Codes are macOS virtual keycodes, i.e. physical key
/// positions on an ANSI layout, so "cmd+c" is the C key whatever input source is active.
enum Keys {
    /// (name, virtual keycode, HID keyboard-page usage or 0 when irrelevant)
    static let table: [(String, CGKeyCode, UInt8)] = [
        ("a", 0, 0x04), ("b", 11, 0x05), ("c", 8, 0x06), ("d", 2, 0x07), ("e", 14, 0x08), ("f", 3, 0x09),
        ("g", 5, 0x0a), ("h", 4, 0x0b), ("i", 34, 0x0c), ("j", 38, 0x0d), ("k", 40, 0x0e), ("l", 37, 0x0f),
        ("m", 46, 0x10), ("n", 45, 0x11), ("o", 31, 0x12), ("p", 35, 0x13), ("q", 12, 0x14), ("r", 15, 0x15),
        ("s", 1, 0x16), ("t", 17, 0x17), ("u", 32, 0x18), ("v", 9, 0x19), ("w", 13, 0x1a), ("x", 7, 0x1b),
        ("y", 16, 0x1c), ("z", 6, 0x1d),
        ("1", 18, 0x1e), ("2", 19, 0x1f), ("3", 20, 0x20), ("4", 21, 0x21), ("5", 23, 0x22),
        ("6", 22, 0x23), ("7", 26, 0x24), ("8", 28, 0x25), ("9", 25, 0x26), ("0", 29, 0x27),
        ("return", 36, 0x28), ("escape", 53, 0x29), ("delete", 51, 0x2a), ("tab", 48, 0x2b), ("space", 49, 0x2c),
        ("-", 27, 0x2d), ("=", 24, 0x2e), ("[", 33, 0x2f), ("]", 30, 0x30), ("\\", 42, 0x31),
        (";", 41, 0x33), ("'", 39, 0x34), ("`", 50, 0x35), (",", 43, 0x36), (".", 47, 0x37), ("/", 44, 0x38),
        ("capslock", 57, 0x39),
        ("f1", 122, 0x3a), ("f2", 120, 0x3b), ("f3", 99, 0x3c), ("f4", 118, 0x3d), ("f5", 96, 0x3e),
        ("f6", 97, 0x3f), ("f7", 98, 0x40), ("f8", 100, 0x41), ("f9", 101, 0x42), ("f10", 109, 0x43),
        ("f11", 103, 0x44), ("f12", 111, 0x45),
        ("f13", 105, 0x68), ("f14", 107, 0x69), ("f15", 113, 0x6a), ("f16", 106, 0x6b), ("f17", 64, 0x6c),
        ("f18", 79, 0x6d), ("f19", 80, 0x6e), ("f20", 90, 0x6f),
        ("help", 114, 0x49), ("home", 115, 0x4a), ("pageup", 116, 0x4b), ("forwarddelete", 117, 0x4c),
        ("end", 119, 0x4d), ("pagedown", 121, 0x4e),
        ("right", 124, 0x4f), ("left", 123, 0x50), ("down", 125, 0x51), ("up", 126, 0x52),
        ("kp0", 82, 0x62), ("kp1", 83, 0x59), ("kp2", 84, 0x5a), ("kp3", 85, 0x5b), ("kp4", 86, 0x5c),
        ("kp5", 87, 0x5d), ("kp6", 88, 0x5e), ("kp7", 89, 0x5f), ("kp8", 91, 0x60), ("kp9", 92, 0x61),
        ("kp.", 65, 0x63), ("kp*", 67, 0x55), ("kp+", 69, 0x57), ("kp-", 78, 0x56), ("kp/", 75, 0x54),
        ("kpenter", 76, 0x58), ("kp=", 81, 0x67), ("kpclear", 71, 0x53),
    ]

    static let aliases: [String: String] = [
        "enter": "return", "esc": "escape", "backspace": "delete", "del": "forwarddelete",
        "pgup": "pageup", "pgdn": "pagedown", "minus": "-", "equal": "=", "equals": "=", "plus": "=",
        "comma": ",", "period": ".", "dot": ".", "slash": "/", "backslash": "\\", "semicolon": ";",
        "quote": "'", "grave": "`", "backtick": "`", "leftbracket": "[", "rightbracket": "]",
        "spacebar": "space", "insert": "help",
    ]

    /// In the order macOS draws them.
    static let modifiers: [KeyModifier] = [
        KeyModifier(name: "ctrl", flag: .maskControl, code: 59, symbol: "⌃"),
        KeyModifier(name: "alt", flag: .maskAlternate, code: 58, symbol: "⌥"),
        KeyModifier(name: "shift", flag: .maskShift, code: 56, symbol: "⇧"),
        KeyModifier(name: "cmd", flag: .maskCommand, code: 55, symbol: "⌘"),
        KeyModifier(name: "fn", flag: .maskSecondaryFn, code: 63, symbol: "fn "),
    ]

    static let modifierAliases: [String: String] = [
        "command": "cmd", "super": "cmd", "win": "cmd", "opt": "alt", "option": "alt", "control": "ctrl",
    ]

    /// How keys are drawn in the app.
    static let symbols: [String: String] = [
        "return": "↩", "escape": "⎋", "delete": "⌫", "forwarddelete": "⌦", "tab": "⇥", "space": "Space",
        "left": "←", "right": "→", "up": "↑", "down": "↓", "pageup": "⇞", "pagedown": "⇟",
        "home": "↖", "end": "↘", "capslock": "⇪", "kpenter": "⌤",
    ]

    static let byName: [String: CGKeyCode] = Dictionary(table.map { ($0.0, $0.1) }, uniquingKeysWith: { a, _ in a })
    static let nameByCode: [CGKeyCode: String] = Dictionary(table.map { ($0.1, $0.0) }, uniquingKeysWith: { a, _ in a })
    static let usageByCode: [CGKeyCode: UInt8] = Dictionary(table.map { ($0.1, $0.2) }, uniquingKeysWith: { a, _ in a })
    static let nameByUsage: [UInt8: String] = Dictionary(table.map { ($0.2, $0.0) }, uniquingKeysWith: { a, _ in a })

    /// Canonical key name for user input ("Enter" -> "return"), nil if unknown.
    static func canonicalName(_ name: String) -> String? {
        let lower = name.lowercased()
        let resolved = aliases[lower] ?? lower
        return byName[resolved] == nil ? nil : resolved
    }

    static func modifier(named name: String) -> KeyModifier? {
        let lower = name.lowercased()
        let resolved = modifierAliases[lower] ?? lower
        return modifiers.first { $0.name == resolved }
    }
}

struct KeyModifier: Equatable {
    let name: String
    let flag: CGEventFlags
    /// The left-hand key.
    let code: CGKeyCode
    let symbol: String
}

/// "cmd+shift+4", "f13", "ctrl" (modifier only).
struct Chord: Equatable, CustomStringConvertible {
    let modifiers: [KeyModifier]
    let keyName: String?

    var key: CGKeyCode? { keyName.flatMap { Keys.byName[$0] } }
    var flags: CGEventFlags { modifiers.reduce(into: CGEventFlags()) { $0.insert($1.flag) } }

    /// Canonical text form, as written to the config file.
    var description: String { (modifiers.map(\.name) + (keyName.map { [$0] } ?? [])).joined(separator: "+") }

    /// "⌃⇧F4"
    var display: String {
        modifiers.map(\.symbol).joined() + (keyName.map { Keys.symbols[$0] ?? $0.uppercased() } ?? "")
    }

    init(modifiers: [KeyModifier], keyName: String?) {
        self.modifiers = modifiers
        self.keyName = keyName
    }

    init(_ text: String) throws {
        var parts = text.split(separator: "+", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        // "cmd++" / "+": a trailing empty part means the key itself is "+".
        if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            parts.removeLast(2)
            parts.append("=")
        }
        var modifiers: [KeyModifier] = []
        var keyName: String?
        for (index, part) in parts.enumerated() {
            if let modifier = Keys.modifier(named: part) {
                if !modifiers.contains(modifier) { modifiers.append(modifier) }
            } else if index == parts.count - 1, let name = Keys.canonicalName(part) {
                keyName = name
            } else {
                throw ConfigError("unknown key \"\(part)\" in \"\(text)\" (run `rzmacro keys` for the list)")
            }
        }
        if modifiers.isEmpty && keyName == nil { throw ConfigError("empty key chord") }
        self.init(modifiers: modifiers, keyName: keyName)
    }
}
