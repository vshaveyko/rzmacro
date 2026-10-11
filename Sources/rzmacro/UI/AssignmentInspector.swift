import SwiftUI

/// The side panel that says what one button does: pick an action from the tiles, fill it in.
struct AssignmentInspector: View {
    @ObservedObject var model: AppModel
    let key: DeviceKey
    /// The profile being edited; nil is the default bindings.
    let profile: String?

    enum ActionKind: String, CaseIterable, Identifiable {
        case shortcut, macro, text, app, open, media, click, light, shell, profile, disabled

        var id: String { rawValue }

        var title: String {
            switch self {
            case .shortcut: return "Shortcut"
            case .macro: return "Macro"
            case .text: return "Text"
            case .app: return "App"
            case .open: return "Link"
            case .media: return "Media"
            case .click: return "Click"
            case .light: return "Light"
            case .shell: return "Shell"
            case .profile: return "Profile"
            case .disabled: return "Off"
            }
        }

        var description: String {
            switch self {
            case .shortcut: return "Press a key or key combination"
            case .macro: return "Play back a recorded sequence"
            case .text: return "Type a piece of text"
            case .app: return "Open or switch to an app"
            case .open: return "Open a web page, file or folder"
            case .media: return "Control playback or volume"
            case .click: return "Click a mouse button"
            case .light: return "Change the lighting"
            case .shell: return "Run a shell command"
            case .profile: return "Switch to another profile"
            case .disabled: return "The button does nothing at all"
            }
        }

        var icon: String { stepKind?.icon ?? "nosign" }

        var stepKind: StepKind? {
            switch self {
            case .shortcut: return .tap
            case .macro: return .macro
            case .text: return .text
            case .app: return .app
            case .open: return .open
            case .media: return .media
            case .click: return .click
            case .light: return .light
            case .shell: return .shell
            case .profile: return .profile
            case .disabled: return nil
            }
        }

        /// nil for "nothing assigned" and for hand-written multi-step assignments.
        init?(_ assignment: Assignment?) {
            guard let assignment else { return nil }
            guard let step = assignment.steps.first else { self = .disabled; return }
            guard assignment.steps.count == 1 else { return nil }
            switch step {
            case .tap: self = .shortcut
            case .text: self = .text
            case .macro: self = .macro
            case .app: self = .app
            case .open: self = .open
            case .shell: self = .shell
            case .media: self = .media
            case .click: self = .click
            case .light: self = .light
            case .profile: self = .profile
            case .down, .up, .delay: return nil
            }
        }
    }

    private enum HoldMode: Hashable { case once, hold, repeating }

    @StateObject private var recorder = KeyCapture()
    /// The macro being recorded into, while the inline recorder runs.
    @State private var recordingMacro: String?
    @State private var assignmentBeforeRecording: Assignment?
    @State private var keepTiming = false
    @State private var lastKeyTime: Date?
    /// "Shortcut" was just chosen: the field should start listening without another click.
    @State private var armShortcut = false

    private var assignment: Assignment? { model.assignment(for: key.trigger, profile: profile) }
    private var kind: ActionKind? { ActionKind(assignment) }
    private var macroNames: [String] { model.config.macros.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }

    private func set(_ assignment: Assignment?) {
        model.setAssignment(assignment, for: key.trigger, profile: profile)
    }

    private func update(_ change: (inout Assignment) -> Void) {
        guard var copy = assignment else { return }
        change(&copy)
        set(copy)
    }

    private func choose(_ new: ActionKind) {
        guard new != kind else { return }
        stopRecording()
        switch new {
        case .disabled:
            set(Assignment(steps: []))
        case .macro:
            // Point at an existing macro if there is one; otherwise the panel offers to record.
            set(Assignment(steps: [.macro(macroNames.first ?? "")]))
        default:
            guard let stepKind = new.stepKind else { return }
            armShortcut = new == .shortcut
            // A key given a key is that key for as long as it is held, unless told otherwise.
            set(Assignment(steps: [stepKind.makeStep(macros: macroNames)], hold: new == .shortcut && key.trigger.isOrdinaryKey))
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let profile, assignment == nil, model.isPartial(profile) {
                    // A partial profile is based on nothing of its own: what shows is the profile in use.
                    let now = model.effective(key.trigger, profile: profile).map { "\($0.assignment.summary), from \($0.from ?? Profile.defaultName)" }
                    Label("\(profile) leaves this button to whichever profile is in use\(now.map { " — right now: \($0)" } ?? ""). Choose an action to change it while \(profile) is on.", systemImage: "arrow.turn.down.right")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let profile, assignment == nil, let inherited = model.effective(key.trigger, profile: profile) {
                    Label("In \(profile) this button does what \(inherited.from ?? Profile.defaultName) says (\(inherited.assignment.summary)). Choose an action to change it here.", systemImage: "arrow.turn.down.right")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let over = model.partialOver(key.trigger, profile: profile) {
                    Label("Right now this button does what \(over.name) says (\(over.assignment.summary)): that partial profile is on, on top of this one.", systemImage: Profile.partialSymbol)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel("Action")
                    actionGrid
                }
                detail
                if kind != nil && kind != .disabled && !key.isMomentary && recordingMacro == nil {
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("While held")
                        holdOptions.panel(padding: 12)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 20)
        }
        .onDisappear { stopRecording() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Text(key.label)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .padding(.horizontal, 3)
                .frame(width: 46, height: 46)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(colors: [Color(rgb: 0x3A4050), Color(rgb: 0x262B37)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: .black.opacity(0.5), radius: 0, y: 2)
                )
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.white.opacity(0.14)))
            VStack(alignment: .leading, spacing: 3) {
                Text(key.title).font(.system(size: 15, weight: .semibold))
                Text(assignment == nil ? "Not assigned — \(key.defaultBehaviour.lowercased())" : (kind?.description ?? "A sequence of steps"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 4)
            if assignment != nil {
                Button("Reset") {
                    stopRecording()
                    set(nil)
                }
                .buttonStyle(PillButtonStyle(compact: true))
                .help("Remove the assignment: \(key.defaultBehaviour.lowercased()) again")
            }
        }
    }

    // MARK: Action tiles

    private var actionGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 6) {
            ForEach(ActionKind.allCases) { action in
                ActionTile(icon: action.icon, title: action.title, isSelected: kind == action) { choose(action) }
                    .help(action.description)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let recordingMacro {
            recordingPanel(recordingMacro)
        } else if let kind, let step = assignment?.steps.first {
            switch kind {
            case .macro:
                macroPicker(current: step)
            default:
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(kind.title)
                    StepValueEditor(step: step, macroNames: macroNames, profileNames: model.config.profiles.map(\.name), roomy: true, recordOnAppear: armShortcut) { new in
                        update { $0.steps = [new] }
                    }
                    if kind == .profile {
                        if case .profile(let name) = step, model.isPartial(name) {
                            Text("\(name) is a partial profile: one press switches it on, the next off.")
                                .font(.system(size: 11.5))
                                .foregroundStyle(Theme.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Text("Profiles are made, and told when to switch on by themselves, on the Profiles page.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if (kind == .shortcut || kind == .text) && !isPlainSwap { keySpeedNote }
                }
            }
        } else if kind == .disabled {
            Label("The button does nothing at all — not even \(key.defaultBehaviour.lowercased()).", systemImage: "nosign")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .panel(padding: 12)
        } else if let steps = assignment?.steps, steps.count > 1 {
            sequencePanel(steps)
        } else {
            Text("Choose what this button should do.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.tertiary)
        }
    }

    // MARK: Macros, picked or recorded on the spot

    private func macroPicker(current step: Step) -> some View {
        let current: String = { if case .macro(let name) = step { return name } else { return "" } }()
        return VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Macro")
            if macroNames.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No macros yet").font(.system(size: 13, weight: .medium))
                    Text("Record one right here: press Record, type the keys, press Stop.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .panel(padding: 12)
            } else {
                VStack(spacing: 2) {
                    ForEach(macroNames, id: \.self) { name in
                        MacroChoiceRow(name: name, steps: model.config.macros[name]?.steps ?? [], isSelected: name == current) {
                            update { $0.steps = [.macro(name)] }
                        }
                    }
                }
                .padding(4)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.black.opacity(0.28)))
            }
            HStack(spacing: 8) {
                Button { startRecording() } label: { Label("Record New", systemImage: "record.circle.fill") }
                    .buttonStyle(PillButtonStyle(kind: .danger))
                Button("Edit Steps") {
                    model.selectedMacro = current
                    model.page = .macros
                }
                .buttonStyle(PillButtonStyle())
                .disabled(model.config.macros[current] == nil)
            }
            Toggle("Keep the pauses between keys when recording", isOn: $keepTiming)
                .toggleStyle(.checkbox)
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.secondary)
            if let macro = model.config.macros[current] {
                SectionLabel("Key speed").padding(.top, 6)
                KeySpeedControl(value: macro.keyDelay, inherited: model.config.keyDelay, compact: true) { model.config.macros[current]?.keyDelay = $0 }
            }
        }
    }

    /// A keyboard key that simply is another key: the keyboard driver's work, not the macro engine's.
    private var isPlainSwap: Bool { key.trigger.isOrdinaryKey && assignment?.remapTarget != nil }

    /// For actions that press keys directly: says how fast, and where that is chosen.
    private var keySpeedNote: some View {
        HStack(spacing: 4) {
            Text(model.config.keyDelay == 0 ? "Keys are pressed instantly." : "Keys are pressed with a \(model.config.keyDelay) ms delay.")
                .foregroundStyle(Theme.tertiary)
            Button("Change") { model.page = .settings }
                .buttonStyle(.plain)
                .foregroundStyle(Theme.accent)
        }
        .font(.system(size: 11.5))
    }

    private func recordingPanel(_ name: String) -> some View {
        let steps = model.config.macros[name]?.steps ?? []
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                RecordingDot()
                Text("Recording “\(name)”").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { stopRecording() } label: { Label("Stop", systemImage: "stop.fill") }
                    .buttonStyle(PillButtonStyle(kind: .danger, compact: true))
            }
            if steps.isEmpty {
                Text("Type the keys now. They are captured here, not sent to other apps.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlowLayout(spacing: 6) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, step in StepChip(step: step) }
                }
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.danger.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.danger.opacity(0.55)))
    }

    private func startRecording() {
        // "M1 macro", "Thumb 6 macro" — and a number if that is taken.
        let base = (key.group == "Thumb grid" ? "Thumb \(key.label)" : (key.group == "Volume roller" ? key.title : key.label)) + " macro"
        var name = base
        var suffix = 2
        while model.config.macros[name] != nil {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        assignmentBeforeRecording = assignment
        model.config.macros[name] = Macro()
        set(Assignment(steps: [.macro(name)]))
        recordingMacro = name
        lastKeyTime = nil
        recorder.start(once: false) { chord in
            let now = Date()
            if keepTiming, let last = lastKeyTime {
                // Rounded to 10 ms: nobody's timing is more deliberate than that.
                let pause = Int((now.timeIntervalSince(last) * 100).rounded()) * 10
                if pause >= 20 { model.config.macros[name, default: Macro()].steps.append(.delay(pause)) }
            }
            lastKeyTime = now
            model.config.macros[name, default: Macro()].steps.append(.tap(chord))
        }
    }

    private func stopRecording() {
        recorder.stop()
        guard let name = recordingMacro else { return }
        recordingMacro = nil
        // Nothing typed: leave no empty macro behind, and put the button back as it was.
        if model.config.macros[name]?.steps.isEmpty == true {
            model.config.macros[name] = nil
            set(assignmentBeforeRecording)
        }
    }

    // MARK: Hand-written sequences

    private func sequencePanel(_ steps: [Step]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel("Sequence")
            FlowLayout(spacing: 6) {
                ForEach(Array(steps.enumerated()), id: \.offset) { _, step in StepChip(step: step) }
            }
            Button("Edit as a Macro") {
                let name = model.addMacro()
                model.config.macros[name] = Macro(steps: steps)
                update { $0.steps = [.macro(name)] }
                model.page = .macros
            }
            .buttonStyle(PillButtonStyle())
        }
    }

    // MARK: Hold behaviour

    @ViewBuilder private var holdOptions: some View {
        let mode: HoldMode = assignment?.hold == true ? .hold : (assignment?.repeatMs != nil ? .repeating : .once)
        let options: [(value: HoldMode, title: String)] = [(.once, "Run once")] + (kind == .shortcut ? [(.hold, "Hold down")] : []) + [(.repeating, "Repeat")]
        VStack(alignment: .leading, spacing: 10) {
            Segmented(options: options, selection: Binding(get: { mode }, set: { new in
                update {
                    $0.hold = new == .hold
                    $0.repeatMs = new == .repeating ? ($0.repeatMs ?? 100) : nil
                    if new != .once { $0.onRelease = false }
                }
            }))
            switch mode {
            case .once:
                Toggle("Run when the button is released", isOn: Binding(get: { assignment?.onRelease ?? false }, set: { new in update { $0.onRelease = new } }))
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            case .hold:
                Text(isPlainSwap
                     ? "The key simply becomes that key. The keyboard driver makes the swap, so it works everywhere — games, password fields — and repeats when held, like the real one."
                     : "The keys stay down for as long as the button is held — a thumb button can be Shift.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .repeating:
                HStack {
                    Text("Every").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                    NumberField(value: assignment?.repeatMs ?? 100, unit: "ms", range: 10...60_000) { new in update { $0.repeatMs = new } }
                }
            }
        }
    }
}

/// One of the action choices at the top of the inspector.
private struct ActionTile: View {
    let icon: String
    let title: String
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .frame(height: 18)
                Text(title).font(.system(size: 10.5, weight: .medium))
            }
            .foregroundStyle(isSelected ? Theme.text : (hovering ? Theme.text : Theme.secondary))
            .frame(maxWidth: .infinity, minHeight: 58)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Theme.accent.opacity(0.26) : (hovering ? Theme.raised : Theme.surface)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: isSelected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A macro in the inspector's list of macros to choose from.
private struct MacroChoiceRow: View {
    let name: String
    let steps: [Step]
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Theme.accent : Theme.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                    Text(steps.isEmpty ? "Empty" : steps.prefix(5).map(\.summary).joined(separator: "  ") + (steps.count > 5 ? "  …" : ""))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(isSelected ? Theme.accent.opacity(0.18) : (hovering ? Color.white.opacity(0.06) : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A step shown as a token: key caps for key presses, a small capsule for everything else.
struct StepChip: View {
    let step: Step

    var body: some View {
        switch step {
        case .tap(let chord):
            ChordView(chord: chord, height: 22)
        default:
            HStack(spacing: 4) {
                Image(systemName: StepKind(step).icon).font(.system(size: 9, weight: .semibold))
                Text(step.summary).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Capsule().fill(Color.white.opacity(0.07)))
            .fixedSize()
        }
    }
}
