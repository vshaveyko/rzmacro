import AppKit
import CoreGraphics
import Foundation

enum MediaKey: Int, CaseIterable {
    case volumeUp = 0, volumeDown = 1, brightnessUp = 2, brightnessDown = 3, mute = 7
    case play = 16, next = 17, previous = 18

    /// Name in the config file.
    var name: String {
        switch self {
        case .volumeUp: return "volume-up"
        case .volumeDown: return "volume-down"
        case .brightnessUp: return "brightness-up"
        case .brightnessDown: return "brightness-down"
        case .mute: return "mute"
        case .play: return "play"
        case .next: return "next"
        case .previous: return "previous"
        }
    }

    var title: String {
        switch self {
        case .volumeUp: return "Volume up"
        case .volumeDown: return "Volume down"
        case .brightnessUp: return "Display brightness up"
        case .brightnessDown: return "Display brightness down"
        case .mute: return "Mute"
        case .play: return "Play / pause"
        case .next: return "Next track"
        case .previous: return "Previous track"
        }
    }

    init?(name: String) {
        let aliases = ["play-pause": "play", "prev": "previous"]
        let lower = name.lowercased()
        guard let key = Self.allCases.first(where: { $0.name == aliases[lower] ?? lower }) else { return nil }
        self = key
    }
}

enum MouseButton: String, CaseIterable {
    case left, right, middle

    var cgButton: CGMouseButton {
        switch self {
        case .left: return .left
        case .right: return .right
        case .middle: return .center
        }
    }
}

enum Step: Equatable {
    case tap(Chord)
    /// Press and keep down — until an `up` step, or until the button running the macro is let go.
    case down(Chord)
    case up(Chord)
    case text(String)
    case delay(Int)
    case shell(String)
    case app(String)
    case open(String)
    case click(MouseButton, Int)
    case media(MediaKey)
    /// Same words as `rzmacro light …`; validated when the config is read.
    case light(String)
    /// Runs a macro from the library by name.
    case macro(String)
    /// Switches to a profile by name; "next" and "previous" step through them, "default" is
    /// the bindings outside any profile, "auto" hands the choice back to the rules.
    case profile(String)
}

/// A named sequence in the macro library.
struct Macro: Equatable {
    var steps: [Step] = []
    /// How this macro presses keys (see `Config.keyDelay`); nil follows the global setting.
    var keyDelay: Int?
}

/// What a button does.
struct Assignment: Equatable {
    var steps: [Step]
    /// Fire when the button is released instead of pressed.
    var onRelease = false
    /// Single chord only: keep it held for as long as the button is held.
    var hold = false
    /// Re-run the steps every N milliseconds while the button is held.
    var repeatMs: Int?
}

private let pauseTimers = DispatchQueue(label: "rzmacro.pause", qos: .userInteractive)

/// Waits this many microseconds — and no longer. `usleep` is not good enough here: macOS
/// stretches the timers of apps in the background, and of everything but the game while one is
/// full screen. Behind Dota a 1.5 ms `usleep` was measured at 45 ms and a 30 ms one at 125,
/// which turned a quick double press into two slow ones. A strict timer is exempt from that
/// (30.1 ms, same conditions).
func pause(_ microseconds: UInt32) {
    guard microseconds > 0 else { return }
    let done = DispatchSemaphore(value: 0)
    let timer = DispatchSource.makeTimerSource(flags: .strict, queue: pauseTimers)
    timer.schedule(deadline: .now() + .microseconds(Int(microseconds)), leeway: .nanoseconds(0))
    timer.setEventHandler { done.signal() }
    timer.resume()
    done.wait()
    timer.cancel()
}

final class MacroEngine {
    /// Stamped on every event we post so our own event tap lets it through.
    static let injectedTag: Int64 = 0x525A_4D43

    /// Lighting belongs to the daemon; called on the main queue.
    var onLight: ((LightCommand) -> Void)?
    /// So do profiles.
    var onProfile: ((String) -> Void)?
    /// Every key and click as it is sent, with the moment it went out — for `rzmacro sniff`,
    /// which is how a macro that "does nothing" gets looked into. Called on a macro's own queue.
    var onSend: ((Date, String) -> Void)?

    private let source: CGEventSource? = {
        let source = CGEventSource(stateID: .hidSystemState)
        source?.userData = MacroEngine.injectedTag
        return source
    }()

    private let lock = NSLock()
    private var queues: [String: DispatchQueue] = [:]
    private var held = Set<String>()
    /// Keys each button's macro is keeping down (its `down` steps), to let go of with the button.
    private var keptDown: [String: [Chord]] = [:]
    private var library: [String: Macro] = [:]
    private var defaultKeyDelay = 0

    /// The named macros `Step.macro` refers to, and how keys are pressed where a macro doesn't say.
    func setLibrary(_ macros: [String: Macro], keyDelay: Int) {
        lock.lock()
        library = macros
        defaultKeyDelay = keyDelay
        lock.unlock()
    }

    private func macro(named name: String) -> Macro? {
        lock.lock()
        defer { lock.unlock() }
        return library[name]
    }

    private var currentDefaultKeyDelay: Int {
        lock.lock()
        defer { lock.unlock() }
        return defaultKeyDelay
    }

    /// Each trigger gets its own serial queue: repeated presses of one button run in order,
    /// different buttons don't wait for each other.
    private func queue(for id: String) -> DispatchQueue {
        lock.lock()
        defer { lock.unlock() }
        if let queue = queues[id] { return queue }
        let queue = DispatchQueue(label: "rzmacro.macro.\(id)", qos: .userInteractive)
        queues[id] = queue
        return queue
    }

    private func isHeld(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return held.contains(id)
    }

    private func setHeld(_ id: String, _ value: Bool) {
        lock.lock()
        if value { held.insert(id) } else { held.remove(id) }
        lock.unlock()
    }

    func press(id: String, assignment: Assignment) {
        setHeld(id, true)
        let queue = queue(for: id)
        if assignment.hold, case .tap(let chord)? = assignment.steps.first, assignment.steps.count == 1 {
            queue.async { self.chord(chord, down: true) }
        } else if assignment.onRelease {
            return
        } else if let interval = assignment.repeatMs {
            queue.async {
                repeat {
                    self.run(assignment.steps, button: id)
                    pause(UInt32(max(interval, 1)) * 1000)
                } while self.isHeld(id)
            }
        } else {
            queue.async { self.run(assignment.steps, button: id) }
        }
    }

    func release(id: String, assignment: Assignment) {
        setHeld(id, false)
        let queue = queue(for: id)
        if assignment.hold, case .tap(let chord)? = assignment.steps.first, assignment.steps.count == 1 {
            queue.async { self.chord(chord, down: false) }
        } else if assignment.onRelease {
            queue.async { self.run(assignment.steps, button: id) }
        }
        // Whatever the macro is keeping down comes up with the button. This waits its turn
        // behind the macro itself, so a release in the middle of a macro is not lost.
        queue.async { self.letGo(of: id) }
    }

    /// Runs a macro once, off the main thread (the "Test" button in the app).
    func play(_ macro: Macro) {
        let id = "test"
        queue(for: id).async {
            // As if a button were pressed, held for the length of the macro, and released.
            self.setHeld(id, true)
            self.run(macro.steps, keyDelay: macro.keyDelay, button: id)
            self.setHeld(id, false)
            self.letGo(of: id)
        }
    }

    private func keep(_ chord: Chord, downFor id: String) {
        lock.lock()
        if keptDown[id]?.contains(chord) != true { keptDown[id, default: []].append(chord) }
        lock.unlock()
    }

    private func forget(_ chord: Chord, downFor id: String) {
        lock.lock()
        keptDown[id]?.removeAll { $0 == chord }
        lock.unlock()
    }

    private func letGo(of id: String) {
        lock.lock()
        let chords = keptDown.removeValue(forKey: id) ?? []
        lock.unlock()
        for chord in chords.reversed() { self.chord(chord, down: false) }
    }

    /// `keyDelay`, in milliseconds, is how long each pressed key is held and the pause that
    /// follows it; 0 is as fast as possible, nil the global setting. `button` is the trigger
    /// the steps run for, which is what `down` steps hold on to.
    func run(_ steps: [Step], keyDelay: Int? = nil, button: String? = nil, depth: Int = 0) {
        let delay = UInt32(max(keyDelay ?? currentDefaultKeyDelay, 0)) * 1000
        for step in steps {
            switch step {
            case .tap(let c):
                chord(c, down: true)
                if delay > 0 { pause(delay) }
                chord(c, down: false)
                if delay > 0 { pause(delay) }
            case .down(let c):
                if let button, !isHeld(button) {
                    // The button is already up (a quick tap): nothing to hold for, so this is
                    // an ordinary press.
                    chord(c, down: true)
                    if delay > 0 { pause(delay) }
                    chord(c, down: false)
                } else {
                    chord(c, down: true)
                    if let button { keep(c, downFor: button) }
                }
                if delay > 0 { pause(delay) }
            case .up(let c):
                chord(c, down: false)
                if let button { forget(c, downFor: button) }
            case .text(let text): type(text, gap: delay)
            case .delay(let ms): pause(UInt32(max(ms, 0)) * 1000)
            case .shell(let command): spawn("/bin/zsh", ["-lc", command])
            case .app(let name): spawn("/usr/bin/open", ["-a", name])
            case .open(let target): spawn("/usr/bin/open", [target])
            case .click(let button, let count): click(button.cgButton, count: count)
            case .media(let key): media(key)
            case .light(let words):
                guard let command = try? LightCommand(words: words.split(separator: " ").map(String.init)) else { continue }
                DispatchQueue.main.async { self.onLight?(command) }
            case .macro(let name):
                // A macro may call another; the depth limit stops one that calls itself.
                // Its own key speed applies if it has one, otherwise the caller's.
                if depth < 8, let macro = macro(named: name) { run(macro.steps, keyDelay: macro.keyDelay ?? keyDelay, button: button, depth: depth + 1) }
            case .profile(let name):
                DispatchQueue.main.async { self.onProfile?(name) }
            }
        }
    }

    // MARK: Event posting

    private func post(_ code: CGKeyCode, down: Bool, flags: CGEventFlags) {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: down) else {
            onSend?(Date(), "COULD NOT MAKE the event for \(Keys.nameByCode[code] ?? "key \(code)")")
            return
        }
        event.flags = flags
        event.post(tap: .cghidEventTap)
        onSend?(Date(), "\(Keys.nameByCode[code] ?? Keys.modifiers.first { $0.code == code }?.name ?? "key \(code)") \(down ? "down" : "up")")
        pause(1_500)
    }

    /// Presses modifiers in order, then the key; releases in reverse.
    private func chord(_ chord: Chord, down: Bool) {
        if down {
            var flags = CGEventFlags()
            for modifier in chord.modifiers {
                flags.insert(modifier.flag)
                post(modifier.code, down: true, flags: flags)
            }
            if let key = chord.key { post(key, down: true, flags: flags) }
        } else {
            var flags = chord.flags
            if let key = chord.key { post(key, down: false, flags: flags) }
            for modifier in chord.modifiers.reversed() {
                flags.remove(modifier.flag)
                post(modifier.code, down: false, flags: flags)
            }
        }
    }

    /// Types arbitrary text independent of the active keyboard layout, `gap` microseconds
    /// between characters (never less than a short pause that keeps them in order).
    private func type(_ text: String, gap: UInt32) {
        for character in text {
            if character == "\n" { post(36, down: true, flags: []); post(36, down: false, flags: []); continue }
            if character == "\t" { post(48, down: true, flags: []); post(48, down: false, flags: []); continue }
            let units = Array(String(character).utf16)
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                event.flags = []
                event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
                event.post(tap: .cghidEventTap)
            }
            pause(max(gap, 2_500))
        }
    }

    func media(_ key: MediaKey) {
        for down in [true, false] {
            let state = down ? 0xa : 0xb
            let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8,
                data1: (key.rawValue << 16) | (state << 8), data2: -1)
            if let cgEvent = event?.cgEvent {
                cgEvent.setIntegerValueField(.eventSourceUserData, value: Self.injectedTag)
                cgEvent.post(tap: .cghidEventTap)
            }
        }
    }

    private func click(_ button: CGMouseButton, count: Int) {
        let position = CGEvent(source: nil)?.location ?? .zero
        let (downType, upType): (CGEventType, CGEventType) = switch button {
        case .left: (.leftMouseDown, .leftMouseUp)
        case .right: (.rightMouseDown, .rightMouseUp)
        default: (.otherMouseDown, .otherMouseUp)
        }
        for n in 1...max(count, 1) {
            for type in [downType, upType] {
                guard let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: position, mouseButton: button) else { continue }
                event.setIntegerValueField(.mouseEventClickState, value: Int64(n))
                event.post(tap: .cghidEventTap)
                onSend?(Date(), "mouse button \(type == downType ? "down" : "up")")
                pause(8_000)
            }
        }
    }

    private func spawn(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = Paths.home
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { log("macro: could not run \(executable) \(arguments): \(error)") }
    }
}
