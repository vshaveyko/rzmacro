import AppKit
import SwiftUI

// MARK: Describing actions

/// What a single step is, for menus, icons and labels.
enum StepKind: String, CaseIterable, Identifiable {
    case tap, down, text, delay, click, media, app, open, macro, profile, light, shell, up

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tap: return "Press"
        case .text: return "Type"
        case .delay: return "Wait"
        case .down: return "Hold"
        case .up: return "Release"
        case .macro: return "Run macro"
        case .profile: return "Switch profile"
        case .app: return "Open app"
        case .open: return "Open"
        case .shell: return "Shell"
        case .media: return "Media"
        case .click: return "Click"
        case .light: return "Lighting"
        }
    }

    var icon: String {
        switch self {
        case .tap: return "command"
        case .text: return "textformat"
        case .delay: return "timer"
        case .down: return "arrow.down.to.line"
        case .up: return "arrow.up.to.line"
        case .macro: return "bolt.fill"
        case .profile: return "square.stack.3d.up.fill"
        case .app: return "macwindow"
        case .open: return "link"
        case .shell: return "terminal"
        case .media: return "playpause.fill"
        case .click: return "cursorarrow.click.2"
        case .light: return "lightbulb.fill"
        }
    }

    init(_ step: Step) {
        switch step {
        case .tap: self = .tap
        case .down: self = .down
        case .up: self = .up
        case .text: self = .text
        case .delay: self = .delay
        case .shell: self = .shell
        case .app: self = .app
        case .open: self = .open
        case .click: self = .click
        case .media: self = .media
        case .light: self = .light
        case .macro: self = .macro
        case .profile: self = .profile
        }
    }

    /// A harmless starting value for a newly added step. F13 does nothing in most apps.
    func makeStep(macros: [String]) -> Step {
        switch self {
        case .tap: return .tap(Chord(modifiers: [], keyName: "f13"))
        case .down: return .down(Chord(modifiers: [Keys.modifiers[2]], keyName: nil))
        case .up: return .up(Chord(modifiers: [Keys.modifiers[2]], keyName: nil))
        case .text: return .text("")
        case .delay: return .delay(100)
        case .shell: return .shell("")
        case .app: return .app("")
        case .open: return .open("")
        case .click: return .click(.left, 1)
        case .media: return .media(.play)
        case .light: return .light("static red")
        case .macro: return .macro(macros.first ?? "")
        case .profile: return .profile("next")
        }
    }
}

extension Step {
    /// One short line, for tiles and lists.
    var summary: String {
        switch self {
        case .tap(let chord): return chord.display
        case .down(let chord): return "hold \(chord.display)"
        case .up(let chord): return "↑ \(chord.display)"
        case .text(let text): return text.isEmpty ? "Text" : "“\(text.replacingOccurrences(of: "\n", with: "⏎"))”"
        case .delay(let ms): return "\(ms) ms"
        case .shell(let command): return command.isEmpty ? "Shell" : command
        case .app(let name): return name.isEmpty ? "App" : URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        case .open(let target): return target.isEmpty ? "Link" : (URL(string: target)?.host ?? URL(fileURLWithPath: target).lastPathComponent)
        case .click(let button, let count): return "\(button.rawValue.capitalized) click" + (count > 1 ? " ×\(count)" : "")
        case .media(let key): return key.title
        case .light(let words): return words.capitalized
        case .macro(let name): return name.isEmpty ? "Macro" : name
        case .profile(let name):
            switch name.lowercased() {
            case "next": return "Next profile"
            case "previous": return "Previous profile"
            case "auto": return "Automatic profile"
            default: return "Profile: \(name.lowercased() == "default" ? Profile.defaultName : name)"
            }
        }
    }
}

extension Assignment {
    var summary: String {
        switch steps.count {
        case 0: return "Disabled"
        case 1: return steps[0].summary
        default: return "\(steps.count) steps"
        }
    }

    var icon: String {
        switch steps.count {
        case 0: return "nosign"
        case 1: return StepKind(steps[0]).icon
        default: return "list.bullet"
        }
    }
}

extension MediaKey {
    var icon: String {
        switch self {
        case .volumeUp: return "speaker.wave.3.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .mute: return "speaker.slash.fill"
        case .play: return "playpause.fill"
        case .next: return "forward.fill"
        case .previous: return "backward.fill"
        case .brightnessUp: return "sun.max.fill"
        case .brightnessDown: return "sun.min.fill"
        }
    }
}

extension KeyModifier {
    var eventFlag: NSEvent.ModifierFlags {
        switch name {
        case "cmd": return .command
        case "ctrl": return .control
        case "alt": return .option
        case "shift": return .shift
        default: return .function
        }
    }
}

extension RGB {
    var color: Color { Color(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue: Double(b) / 255) }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: UInt8((ns.redComponent * 255).rounded()), g: UInt8((ns.greenComponent * 255).rounded()), b: UInt8((ns.blueComponent * 255).rounded()))
    }
}

// MARK: Keys, drawn

/// One key of a shortcut, drawn as a key cap.
struct KeyChip: View {
    let text: String
    var height: CGFloat = 22

    var body: some View {
        Text(text)
            .font(.system(size: height * 0.52, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, height * 0.3)
            .frame(minWidth: height, minHeight: height, maxHeight: height)
            .background(
                RoundedRectangle(cornerRadius: height * 0.27, style: .continuous)
                    .fill(LinearGradient(colors: [Color(rgb: 0x3A4050), Color(rgb: 0x2A2F3C)], startPoint: .top, endPoint: .bottom))
                    .shadow(color: .black.opacity(0.5), radius: 0, y: 1.5)
            )
            .overlay(RoundedRectangle(cornerRadius: height * 0.27, style: .continuous).strokeBorder(Color.white.opacity(0.13)))
            .fixedSize()
    }
}

/// A shortcut as a row of key caps: ⌘ ⇧ 4.
struct ChordView: View {
    let chord: Chord
    var height: CGFloat = 22

    private var parts: [String] {
        chord.modifiers.map { $0.symbol.trimmingCharacters(in: .whitespaces) } + (chord.keyName.map { [Keys.symbols[$0] ?? $0.uppercased()] } ?? [])
    }

    var body: some View {
        HStack(spacing: height * 0.16) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in KeyChip(text: part, height: height) }
        }
    }
}

// MARK: Recording key presses

/// Captures key presses made in the app's own window while it is active.
final class KeyCapture: ObservableObject {
    @Published private(set) var isActive = false
    private var monitor: Any? {
        didSet { if (monitor == nil) != (oldValue == nil) { Self.running += monitor == nil ? -1 : 1 } }
    }
    /// How many captures are listening, anywhere in the window.
    private static var running = 0 {
        didSet { if (running > 0) != (oldValue > 0) { onActivity?(running > 0) } }
    }
    /// Told when capturing starts and stops. While it runs the keyboard's keys must be
    /// themselves: what gets recorded is the key pressed, not what a profile makes of it.
    static var onActivity: ((Bool) -> Void)?
    /// The most modifiers held at once since capture started, for modifier-only shortcuts.
    private var peak: [KeyModifier] = []

    /// Modifiers a shortcut can use. Fn is left out: macOS sets it by itself on arrows and F-keys.
    private static func modifiers(of event: NSEvent) -> [KeyModifier] {
        Keys.modifiers.filter { $0.name != "fn" && event.modifierFlags.contains($0.eventFlag) }
    }

    /// Calls `onChord` for every key press (auto-repeats skipped) until `stop()`.
    /// With `once`, stops after the first one — and a press and release of only modifiers counts.
    func start(once: Bool, onChord: @escaping (Chord) -> Void) {
        stop()
        peak = []
        isActive = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let held = Self.modifiers(of: event)
            if event.type == .keyDown {
                guard !event.isARepeat, let name = Keys.nameByCode[CGKeyCode(event.keyCode)] else { return nil }
                onChord(Chord(modifiers: held, keyName: name))
                if once { self.stop() }
                return nil
            }
            if once {
                if held.isEmpty, !self.peak.isEmpty {
                    onChord(Chord(modifiers: self.peak, keyName: nil))
                    self.stop()
                } else if held.count > self.peak.count {
                    self.peak = held
                }
            }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isActive { isActive = false }
    }

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            Self.running -= 1
        }
    }
}

/// A dot that pulses while something is being recorded.
struct RecordingDot: View {
    @State private var dim = false

    var body: some View {
        Circle()
            .fill(Theme.danger)
            .frame(width: 9, height: 9)
            .opacity(dim ? 0.35 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) { dim = true } }
    }
}

/// Shows a shortcut as key caps and records a new one when clicked.
struct ShortcutField: View {
    let chord: Chord?
    /// Start listening as soon as the field appears (it was just chosen as the action).
    var recordOnAppear = false
    /// The small form used inside macro step rows.
    var compact = false
    let onChange: (Chord) -> Void

    @StateObject private var capture = KeyCapture()
    @State private var hovering = false

    var body: some View {
        Button {
            if capture.isActive { capture.stop() } else { capture.start(once: true, onChord: onChange) }
        } label: {
            HStack(spacing: 8) {
                if capture.isActive {
                    RecordingDot()
                    Text(compact ? "Press keys…" : "Press the shortcut…")
                        .font(.system(size: compact ? 12 : 13, weight: .medium))
                        .foregroundStyle(Theme.text)
                } else if let chord {
                    ChordView(chord: chord, height: compact ? 22 : 28)
                    if !compact {
                        Spacer(minLength: 8)
                        Text("Click to change").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    }
                } else {
                    Image(systemName: "keyboard").foregroundStyle(Theme.secondary)
                    Text("Click to record").font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, compact ? 6 : 12)
            .frame(maxWidth: compact ? nil : .infinity, minHeight: compact ? 30 : 48, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous).fill(capture.isActive ? Theme.danger.opacity(0.14) : Color.black.opacity(hovering ? 0.38 : 0.28)))
            .overlay(RoundedRectangle(cornerRadius: compact ? 8 : 10, style: .continuous).strokeBorder(capture.isActive ? Theme.danger.opacity(0.7) : (hovering ? Theme.strokeStrong : Theme.stroke)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Click, then press the shortcut. Modifiers alone work too: press and release them.")
        .onAppear { if recordOnAppear { capture.start(once: true, onChord: onChange) } }
        .onDisappear { capture.stop() }
    }
}

/// Number entry with a unit, e.g. "80 ms".
struct NumberField: View {
    let value: Int
    let unit: String
    var range: ClosedRange<Int> = 0...600_000
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: Binding(get: { value }, set: { onChange(min(max($0, range.lowerBound), range.upperBound)) }), format: .number.grouping(.never))
                .multilineTextAlignment(.trailing)
                .field()
                .frame(width: 74)
            Text(unit).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }
}

/// Chooses how keys are pressed: back to back, or each held for a while with the same pause after.
struct KeySpeedControl: View {
    /// Milliseconds; 0 is instant; nil follows `inherited`.
    let value: Int?
    /// The setting this one falls back to. nil when this control is that setting itself.
    var inherited: Int?
    /// Stack the parts vertically (the narrow inspector).
    var compact = false
    let onChange: (Int?) -> Void

    private enum Mode: Hashable { case inherit, instant, delayed }

    /// The delay to go back to when "With delay" is chosen again.
    @State private var lastDelay = 30

    private var mode: Mode { value.map { $0 == 0 ? .instant : .delayed } ?? .inherit }

    private var options: [(value: Mode, title: String)] {
        (inherited == nil ? [] : [(Mode.inherit, "Default")]) + [(Mode.instant, "Instant"), (Mode.delayed, "With delay")]
    }

    var body: some View {
        let layout = compact ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            Segmented(options: options, selection: Binding(get: { mode }, set: { new in
                switch new {
                case .inherit: onChange(nil)
                case .instant: onChange(0)
                case .delayed: onChange(lastDelay)
                }
            }))
            .frame(maxWidth: compact ? .infinity : (inherited == nil ? 230 : 320))
            if let value, value > 0 {
                NumberField(value: value, unit: "ms", range: 1...2000) { new in
                    lastDelay = new
                    onChange(new)
                }
            } else if mode == .inherit, let inherited {
                Text(inherited == 0 ? "Default is instant" : "Default is a \(inherited) ms delay")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiary)
            }
        }
        .onAppear { if let value, value > 0 { lastDelay = value } }
        .help("Instant: presses go out back to back. With delay: each key is held for this many milliseconds, then the same pause follows.")
    }
}
