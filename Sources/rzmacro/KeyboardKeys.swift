import Foundation
import IOKit.hid

/// An ordinary key of a keyboard, as a button that can be given something else to do.
struct PhysicalKey {
    /// HID keyboard-page usage: what the keyboard itself calls the key.
    let usage: UInt8
    /// Name in the config file: "capslock", "left-cmd".
    let name: String
    /// What the key cap says, short enough to fit on one.
    let legend: String
    /// Full name: "Caps Lock".
    let title: String

    /// The legend, told apart from the other key that says the same: "R Shift", "KP 1".
    var label: String {
        if name.hasPrefix("kp") { return "KP \(legend)" }
        if name.hasPrefix("left-") { return "L \(legend)" }
        if name.hasPrefix("right-") { return "R \(legend)" }
        return legend
    }
}

/// Every ordinary key RZMacro knows by name. A key that is not here can still be assigned,
/// as `keyboard.key:XX` with its usage.
enum KeyboardKeys {
    static let all: [PhysicalKey] = {
        var keys: [PhysicalKey] = []
        // Letters, digits and function keys are called what they type.
        for (name, _, usage) in Keys.table {
            let isPlain = name.count == 1 && (name.first!.isLetter || name.first!.isNumber)
            let isFunction = name.hasPrefix("f") && Int(name.dropFirst()) != nil
            if isPlain || isFunction { keys.append(PhysicalKey(usage: usage, name: name, legend: name.uppercased(), title: name.uppercased())) }
        }
        keys += [
            PhysicalKey(usage: 0x29, name: "escape", legend: "Esc", title: "Escape"),
            PhysicalKey(usage: 0x35, name: "grave", legend: "`", title: "Backtick"),
            PhysicalKey(usage: 0x2d, name: "minus", legend: "-", title: "Minus"),
            PhysicalKey(usage: 0x2e, name: "equal", legend: "=", title: "Equals"),
            PhysicalKey(usage: 0x2a, name: "delete", legend: "⌫", title: "Backspace"),
            PhysicalKey(usage: 0x2b, name: "tab", legend: "Tab", title: "Tab"),
            PhysicalKey(usage: 0x2f, name: "leftbracket", legend: "[", title: "Left Bracket"),
            PhysicalKey(usage: 0x30, name: "rightbracket", legend: "]", title: "Right Bracket"),
            PhysicalKey(usage: 0x31, name: "backslash", legend: "\\", title: "Backslash"),
            PhysicalKey(usage: 0x39, name: "capslock", legend: "Caps", title: "Caps Lock"),
            PhysicalKey(usage: 0x33, name: "semicolon", legend: ";", title: "Semicolon"),
            PhysicalKey(usage: 0x34, name: "quote", legend: "'", title: "Quote"),
            PhysicalKey(usage: 0x28, name: "return", legend: "Enter", title: "Enter"),
            PhysicalKey(usage: 0x36, name: "comma", legend: ",", title: "Comma"),
            PhysicalKey(usage: 0x37, name: "period", legend: ".", title: "Period"),
            PhysicalKey(usage: 0x38, name: "slash", legend: "/", title: "Slash"),
            PhysicalKey(usage: 0x2c, name: "space", legend: "Space", title: "Space"),
            PhysicalKey(usage: 0x65, name: "menu", legend: "Menu", title: "Menu"),
            PhysicalKey(usage: 0x32, name: "non-us-hash", legend: "#", title: "Non-US #"),
            PhysicalKey(usage: 0x64, name: "non-us-backslash", legend: "\\", title: "Non-US \\"),

            PhysicalKey(usage: 0xe0, name: "left-ctrl", legend: "Ctrl", title: "Left Control"),
            PhysicalKey(usage: 0xe1, name: "left-shift", legend: "Shift", title: "Left Shift"),
            PhysicalKey(usage: 0xe2, name: "left-alt", legend: "⌥", title: "Left Option (Alt)"),
            PhysicalKey(usage: 0xe3, name: "left-cmd", legend: "⌘", title: "Left Command (Win)"),
            PhysicalKey(usage: 0xe4, name: "right-ctrl", legend: "Ctrl", title: "Right Control"),
            PhysicalKey(usage: 0xe5, name: "right-shift", legend: "Shift", title: "Right Shift"),
            PhysicalKey(usage: 0xe6, name: "right-alt", legend: "⌥", title: "Right Option (Alt)"),
            PhysicalKey(usage: 0xe7, name: "right-cmd", legend: "⌘", title: "Right Command (Win)"),

            PhysicalKey(usage: 0x46, name: "printscreen", legend: "Prt", title: "Print Screen"),
            PhysicalKey(usage: 0x47, name: "scrolllock", legend: "Scr", title: "Scroll Lock"),
            PhysicalKey(usage: 0x48, name: "pause", legend: "Pau", title: "Pause"),
            PhysicalKey(usage: 0x49, name: "insert", legend: "Ins", title: "Insert"),
            PhysicalKey(usage: 0x4a, name: "home", legend: "Hm", title: "Home"),
            PhysicalKey(usage: 0x4b, name: "pageup", legend: "PgU", title: "Page Up"),
            PhysicalKey(usage: 0x4c, name: "forwarddelete", legend: "Del", title: "Delete"),
            PhysicalKey(usage: 0x4d, name: "end", legend: "End", title: "End"),
            PhysicalKey(usage: 0x4e, name: "pagedown", legend: "PgD", title: "Page Down"),
            PhysicalKey(usage: 0x4f, name: "right", legend: "→", title: "Right Arrow"),
            PhysicalKey(usage: 0x50, name: "left", legend: "←", title: "Left Arrow"),
            PhysicalKey(usage: 0x51, name: "down", legend: "↓", title: "Down Arrow"),
            PhysicalKey(usage: 0x52, name: "up", legend: "↑", title: "Up Arrow"),

            PhysicalKey(usage: 0x53, name: "numlock", legend: "Num", title: "Num Lock"),
            PhysicalKey(usage: 0x54, name: "kp-divide", legend: "/", title: "Keypad /"),
            PhysicalKey(usage: 0x55, name: "kp-multiply", legend: "*", title: "Keypad *"),
            PhysicalKey(usage: 0x56, name: "kp-minus", legend: "-", title: "Keypad -"),
            PhysicalKey(usage: 0x57, name: "kp-plus", legend: "+", title: "Keypad +"),
            PhysicalKey(usage: 0x58, name: "kp-enter", legend: "↩", title: "Keypad Enter"),
            PhysicalKey(usage: 0x63, name: "kp-dot", legend: ".", title: "Keypad ."),
            PhysicalKey(usage: 0x67, name: "kp-equal", legend: "=", title: "Keypad ="),
        ]
        // Keypad 1…9, then 0.
        for digit in 0...9 {
            let usage = digit == 0 ? 0x62 : UInt8(0x58 + digit)
            keys.append(PhysicalKey(usage: UInt8(usage), name: "kp\(digit)", legend: "\(digit)", title: "Keypad \(digit)"))
        }
        return keys
    }()

    static let byUsage: [UInt8: PhysicalKey] = Dictionary(all.map { ($0.usage, $0) }, uniquingKeysWith: { first, _ in first })
    static let byName: [String: PhysicalKey] = Dictionary(all.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

    /// The usage of a key named the way the config file names them — or the way shortcuts do
    /// ("esc", "backspace", "kp+"), since nobody remembers which is which.
    static func usage(named name: String) -> UInt8? {
        let lower = name.lowercased()
        if let key = byName[lower] { return key.usage }
        guard let usage = Keys.canonicalName(lower).flatMap({ Keys.usageByName[$0] }), usage != 0 else { return nil }
        return usage
    }
}

extension Trigger {
    /// An ordinary key of the keyboard — a letter, Caps Lock, a modifier — rather than one of
    /// its special buttons.
    var isOrdinaryKey: Bool {
        if kind == .keyboard, case .key = source { return true }
        return false
    }

    /// A key typed with modifiers held, rather than a key by itself.
    var isCombination: Bool {
        if case .combo = source { return true }
        return false
    }

    /// Something typed on the keyboard — a key, or a combination of them — rather than one of
    /// its special buttons.
    var isTyped: Bool { isOrdinaryKey || isCombination }
}
