import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The control that edits one step's value; which control depends on the kind of step.
/// `roomy` is the inspector's wide form, otherwise the compact form used in macro rows.
struct StepValueEditor: View {
    let step: Step
    /// Macros this step may run (the one being edited is left out by the caller).
    let macroNames: [String]
    var roomy = false
    /// Start listening for a shortcut as soon as the editor appears.
    var recordOnAppear = false
    let onChange: (Step) -> Void

    private func text(_ value: String, _ make: @escaping (String) -> Step) -> Binding<String> {
        Binding(get: { value }, set: { onChange(make($0)) })
    }

    var body: some View {
        switch step {
        case .tap(let chord):
            ShortcutField(chord: chord, recordOnAppear: recordOnAppear, compact: !roomy) { onChange(.tap($0)) }
        case .down(let chord):
            ShortcutField(chord: chord, compact: !roomy) { onChange(.down($0)) }
        case .up(let chord):
            ShortcutField(chord: chord, compact: !roomy) { onChange(.up($0)) }
        case .text(let value):
            TextField("Text to type", text: text(value) { .text($0) }, axis: .vertical)
                .lineLimit(roomy ? 3...8 : 1...4)
                .field()
        case .delay(let ms):
            NumberField(value: ms, unit: "ms") { onChange(.delay($0)) }
        case .shell(let command):
            TextField("say hello", text: text(command) { .shell($0) }, axis: .vertical)
                .lineLimit(roomy ? 3...8 : 1...4)
                .field(monospaced: true)
        case .app(let name):
            HStack(spacing: 8) {
                AppIcon(name: name)
                TextField("App name", text: text(name) { .app($0) }).field()
                Button("Choose…") { chooseApp() }.buttonStyle(PillButtonStyle(compact: true))
            }
        case .open(let target):
            HStack(spacing: 8) {
                TextField("https://… or a path", text: text(target) { .open($0) }).field()
                Button("Choose…") { chooseFile() }.buttonStyle(PillButtonStyle(compact: true))
            }
        case .click(let button, let count):
            HStack(spacing: 10) {
                Segmented(options: MouseButton.allCases.map { ($0, $0.rawValue.capitalized) }, selection: Binding(get: { button }, set: { onChange(.click($0, count)) }))
                    .frame(width: 190)
                Stepper("×\(count)", value: Binding(get: { count }, set: { onChange(.click(button, $0)) }), in: 1...5)
                    .font(.system(size: 12))
            }
        case .media(let key):
            MediaPicker(selection: key) { onChange(.media($0)) }
        case .light(let words):
            LightWordsField(words: words) { onChange(.light($0)) }
        case .macro(let name):
            Picker("", selection: Binding(get: { name }, set: { onChange(.macro($0)) })) {
                if !macroNames.contains(name) { Text(name.isEmpty ? "Choose a macro…" : "\(name) (missing)").tag(name) }
                ForEach(macroNames, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(maxWidth: 240)
        }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // `open -a` finds installed apps by name; anything elsewhere needs its path.
        let standard = ["/Applications", "/System/Applications"].contains(url.deletingLastPathComponent().path)
        onChange(.app(standard ? url.deletingPathExtension().lastPathComponent : url.path))
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        onChange(.open(url.path))
    }
}

/// The icon of an app given the way `open -a` names it: a bare name or a path.
struct AppIcon: View {
    let name: String
    var size: CGFloat = 26

    private var image: NSImage? {
        guard !name.isEmpty else { return nil }
        if name.hasPrefix("/") { return NSWorkspace.shared.icon(forFile: name) }
        for folder in ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"] {
            let path = "\(folder)/\(name).app"
            if FileManager.default.fileExists(atPath: path) { return NSWorkspace.shared.icon(forFile: path) }
        }
        return nil
    }

    var body: some View {
        if let image {
            Image(nsImage: image).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "macwindow")
                .foregroundStyle(Theme.tertiary)
                .frame(width: size, height: size)
        }
    }
}

/// Media keys as a row of icon buttons rather than a menu.
private struct MediaPicker: View {
    let selection: MediaKey
    let onChange: (MediaKey) -> Void

    private static let keys: [MediaKey] = [.previous, .play, .next, .mute, .volumeDown, .volumeUp]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(Self.keys, id: \.self) { key in
                Button { onChange(key) } label: {
                    Image(systemName: key.icon)
                        .font(.system(size: 13))
                        .foregroundStyle(selection == key ? Theme.text : Theme.secondary)
                        .frame(width: 40, height: 34)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selection == key ? Theme.accent.opacity(0.28) : Color.black.opacity(0.28)))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(selection == key ? Theme.accent : Theme.stroke))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(key.title)
            }
        }
    }
}

/// Lighting steps are written as the words of `rzmacro light …`. Only text that parses is
/// committed, because a config file with an invalid one would not load.
private struct LightWordsField: View {
    let words: String
    let onChange: (String) -> Void
    @State private var draft = ""

    private static let presets: [(title: String, words: String)] = [
        ("Red", "static red"), ("Green", "static green"), ("Blue", "static blue"), ("White", "static white"),
        ("Spectrum", "spectrum"), ("Wave", "wave"), ("Off", "off"), ("Brighter", "brightness +10"), ("Dimmer", "brightness -10"),
    ]

    private func isValid(_ text: String) -> Bool {
        (try? LightCommand(words: text.split(separator: " ").map(String.init))) != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowLayout(spacing: 6) {
                ForEach(Self.presets, id: \.words) { preset in
                    Button(preset.title) { draft = preset.words }
                        .buttonStyle(PillButtonStyle(kind: draft == preset.words ? .primary : .secondary, compact: true))
                }
            }
            TextField("static #ff8800", text: $draft)
                .field(monospaced: true)
                .onChange(of: draft) { _, new in if isValid(new) && new != words { onChange(new) } }
            if !isValid(draft) {
                Text("Not a lighting command — pick one above.").font(.system(size: 11)).foregroundStyle(Theme.danger)
            }
        }
        .onAppear { draft = words }
        .onChange(of: words) { _, new in if new != draft { draft = new } }
    }
}
