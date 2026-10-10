import AppKit
import SwiftUI

/// The macro library: named sequences, recorded or built by hand, that buttons can run.
struct MacrosPage: View {
    @ObservedObject var model: AppModel

    @StateObject private var capture = KeyCapture()
    @State private var keepTiming = false
    @State private var lastKeyTime: Date?
    @State private var nameDraft = ""
    @State private var testCountdown: Int?
    @FocusState private var nameFocused: Bool

    private var names: [String] { model.config.macros.keys.sorted { $0.localizedStandardCompare($1) == .orderedAscending } }
    private var selection: String? { model.selectedMacro.flatMap { model.config.macros[$0] == nil ? nil : $0 } }

    var body: some View {
        HStack(spacing: 0) {
            library.frame(width: 268)
            Rectangle().fill(Theme.stroke).frame(width: 1).padding(.top, -Theme.titleBarOverlap)
            if let name = selection {
                editor(name)
            } else {
                emptyState
            }
        }
        .onAppear {
            if selection == nil { model.selectedMacro = names.first }
            nameDraft = selection ?? ""
        }
        .onChange(of: model.selectedMacro) {
            capture.stop()
            nameDraft = selection ?? ""
        }
        .onDisappear { capture.stop() }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 26))
                .foregroundStyle(Theme.accent)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Theme.accent.opacity(0.15)))
            Text(names.isEmpty ? "No macros yet" : "Select a macro").font(.system(size: 16, weight: .semibold))
            Text("A macro is a sequence — keys, text, pauses, clicks — that a button plays back.\nRecord one by typing it, or build it step by step.")
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button { _ = model.addMacro() } label: { Label("New Macro", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(kind: .primary))
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Macros").font(.system(size: 24, weight: .bold))
                Spacer()
                Button { _ = model.addMacro() } label: { Image(systemName: "plus").font(.system(size: 12, weight: .bold)).frame(width: 28, height: 28) }
                    .buttonStyle(.plain)
                    .background(Circle().fill(Theme.accent))
                    .help("New macro")
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(names, id: \.self) { name in
                        MacroCard(
                            name: name, steps: model.config.macros[name]?.steps ?? [], usage: model.usage(ofMacro: name),
                            isSelected: selection == name,
                            onSelect: { model.selectedMacro = name },
                            onDelete: { delete(name) })
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .background(Theme.sidebar.opacity(0.6).padding(.top, -Theme.titleBarOverlap))
    }

    private func delete(_ name: String) {
        let usage = model.usage(ofMacro: name)
        if !steps(name).isEmpty || !usage.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Delete “\(name)”?"
            alert.informativeText = usage.isEmpty ? "This can't be undone." : "It is assigned to \(usage.joined(separator: ", ")); those buttons will do nothing until reassigned."
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        model.deleteMacro(name)
    }

    // MARK: Editor

    private func steps(_ name: String) -> [Step] { model.config.macros[name]?.steps ?? [] }

    private func editor(_ name: String) -> some View {
        let steps = steps(name)
        return ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                titleRow(name, steps)
                recordBar(name, steps)
                HStack(spacing: 12) {
                    Text("Key speed").font(.system(size: 12.5, weight: .medium)).foregroundStyle(Theme.secondary)
                    KeySpeedControl(value: model.config.macros[name]?.keyDelay, inherited: model.config.keyDelay) { model.config.macros[name]?.keyDelay = $0 }
                    Spacer(minLength: 0)
                }
                .help("How this macro presses keys: back to back, or each held for a while with the same pause after. Default follows Settings.")
                if steps.isEmpty && !capture.isActive {
                    Text("No steps yet. Press Record and type the keys, or add steps one by one below.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 34)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.strokeStrong, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                            StepRow(
                                index: index, count: steps.count, step: step, macroNames: names.filter { $0 != name },
                                profileNames: model.config.profiles.map(\.name),
                                onChange: { replace(index, in: name, with: $0) },
                                onMove: { move(index, by: $0, in: name) },
                                onDuplicate: { model.config.macros[name]?.steps.insert(step, at: index + 1) },
                                onDelete: { model.config.macros[name]?.steps.remove(at: index) })
                        }
                    }
                }
                addBar(name)
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 28)
        }
    }

    private func titleRow(_ name: String, _ steps: [Step]) -> some View {
        let usage = model.usage(ofMacro: name)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                TextField("Macro name", text: $nameDraft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 22, weight: .bold))
                    .focused($nameFocused)
                    .onSubmit { commitName(name) }
                    .onChange(of: nameFocused) { _, focused in if !focused { commitName(name) } }
                Button {
                    testCountdown = 3
                    tick(name)
                } label: {
                    Label(testCountdown.map { "Runs in \($0)…" } ?? "Test", systemImage: "play.fill")
                }
                .buttonStyle(PillButtonStyle())
                .disabled(steps.isEmpty || testCountdown != nil || capture.isActive)
                .help("Runs the macro after 3 seconds, so you can click into the app it is meant for.")
            }
            HStack(spacing: 6) {
                ForEach(usage, id: \.self) { place in
                    Text(place)
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Theme.accent.opacity(0.25)))
                }
                assignMenu(name)
                if usage.isEmpty {
                    Text("Not on any button yet").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    /// Puts the macro on a button without leaving the page.
    private func assignMenu(_ name: String) -> some View {
        Menu {
            ForEach(DeviceKind.allCases, id: \.self) { kind in
                let keys = model.keys(for: kind)
                if !keys.isEmpty {
                    Section(kind == .keyboard ? "Keyboard" : "Mouse") {
                        ForEach(keys) { key in
                            let current = model.config.bindings[key.trigger]
                            Button {
                                model.config.bindings[key.trigger] = Assignment(steps: [.macro(name)])
                            } label: {
                                Text(current == nil ? key.title : "\(key.title) — replaces \(current!.summary)")
                            }
                            .disabled(current?.steps == [.macro(name)])
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "plus").font(.system(size: 9, weight: .bold))
                Text("Assign to button").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().strokeBorder(Theme.strokeStrong))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func recordBar(_ name: String, _ steps: [Step]) -> some View {
        HStack(spacing: 12) {
            Button {
                if capture.isActive { capture.stop() } else { startRecording(name) }
            } label: {
                HStack(spacing: 8) {
                    if capture.isActive { RecordingDot() } else { Circle().fill(Theme.danger).frame(width: 9, height: 9) }
                    Text(capture.isActive ? "Stop Recording" : "Record").font(.system(size: 13, weight: .semibold))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Capsule().fill(Theme.danger.opacity(capture.isActive ? 0.30 : 0.16)))
                .overlay(Capsule().strokeBorder(Theme.danger.opacity(0.6)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            if capture.isActive {
                Text("Type the keys of the macro. They are captured here, not sent anywhere.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            } else {
                Toggle("Keep the pauses between keys", isOn: $keepTiming)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            if !steps.isEmpty && !capture.isActive {
                Button("Clear") { model.config.macros[name]?.steps = [] }.buttonStyle(PillButtonStyle(compact: true))
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(capture.isActive ? Theme.danger.opacity(0.08) : Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(capture.isActive ? Theme.danger.opacity(0.5) : Theme.stroke))
    }

    /// The step kinds people reach for most, one click each; the rest under "More".
    private func addBar(_ name: String) -> some View {
        let others = names.filter { $0 != name }
        return HStack(spacing: 6) {
            Text("Add").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            ForEach([StepKind.tap, .down, .text, .delay, .click], id: \.self) { kind in
                Button { append(kind.makeStep(macros: others), to: name) } label: { Label(kind.title, systemImage: kind.icon) }
                    .buttonStyle(PillButtonStyle(compact: true))
            }
            Menu {
                ForEach([StepKind.media, .app, .open, .macro, .profile, .light, .shell, .up], id: \.self) { kind in
                    Button { append(kind.makeStep(macros: others), to: name) } label: { Label(kind.title, systemImage: kind.icon) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text("More").font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.tertiary)
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            Spacer()
        }
    }

    /// Applies the name field; an empty or already-used name is put back.
    private func commitName(_ name: String) {
        guard nameDraft != name else { return }
        if !model.renameMacro(name, to: nameDraft) { nameDraft = name }
    }

    private func append(_ step: Step, to name: String) {
        model.config.macros[name, default: Macro()].steps.append(step)
    }

    private func replace(_ index: Int, in name: String, with step: Step) {
        guard model.config.macros[name]?.steps.indices.contains(index) == true else { return }
        model.config.macros[name]?.steps[index] = step
    }

    private func move(_ index: Int, by offset: Int, in name: String) {
        guard var steps = model.config.macros[name]?.steps, steps.indices.contains(index + offset) else { return }
        steps.swapAt(index, index + offset)
        model.config.macros[name]?.steps = steps
    }

    // MARK: Recording and testing

    private func startRecording(_ name: String) {
        nameFocused = false
        lastKeyTime = nil
        capture.start(once: false) { chord in
            let now = Date()
            if keepTiming, let last = lastKeyTime {
                // Rounded to 10 ms: nobody's timing is more deliberate than that.
                let pause = Int((now.timeIntervalSince(last) * 100).rounded()) * 10
                if pause >= 20 { append(.delay(pause), to: name) }
            }
            lastKeyTime = now
            append(.tap(chord), to: name)
        }
    }

    private func tick(_ name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard let remaining = testCountdown else { return }
            if remaining > 1 {
                testCountdown = remaining - 1
                tick(name)
            } else {
                testCountdown = nil
                if let macro = model.config.macros[name] { model.daemon.play(macro) }
            }
        }
    }
}

/// A macro in the library list.
private struct MacroCard: View {
    let name: String
    let steps: [Step]
    let usage: [String]
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 5) {
                    Text(steps.isEmpty ? "Empty" : "\(steps.count) step\(steps.count == 1 ? "" : "s")")
                    if !usage.isEmpty {
                        Text("·")
                        Image(systemName: "bolt.fill").font(.system(size: 8))
                        Text(usage.joined(separator: ", ")).lineLimit(1)
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Theme.text.opacity(0.75) : Theme.tertiary)
            }
            Spacer(minLength: 0)
            if hovering {
                IconButton(symbol: "trash", help: "Delete this macro", action: onDelete)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Theme.accent.opacity(0.24) : (hovering ? Color.white.opacity(0.05) : Color.clear)))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovering = $0 }
        .contextMenu { Button("Delete", role: .destructive, action: onDelete) }
    }
}

/// One step of a macro, on a timeline: what kind it is, its value, and its controls on hover.
private struct StepRow: View {
    let index: Int
    let count: Int
    let step: Step
    let macroNames: [String]
    let profileNames: [String]
    let onChange: (Step) -> Void
    let onMove: (Int) -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    @State private var hovering = false

    private var kind: StepKind { StepKind(step) }
    private var isPause: Bool { kind == .delay }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            // The timeline: a line through every row, with this step's marker on it.
            ZStack {
                Rectangle()
                    .fill(Theme.strokeStrong)
                    .frame(width: 1.5)
                    .padding(.top, index == 0 ? 22 : 0)
                    .padding(.bottom, index == count - 1 ? 22 : 0)
                Image(systemName: kind.icon)
                    .font(.system(size: isPause ? 9 : 11, weight: .semibold))
                    .foregroundStyle(isPause ? Theme.secondary : Theme.text)
                    .frame(width: isPause ? 20 : 28, height: isPause ? 20 : 28)
                    .background(Circle().fill(isPause ? Theme.raised : Theme.accent.opacity(0.85)))
                    .overlay(Circle().strokeBorder(Theme.window, lineWidth: 3))
            }
            .frame(width: 30)

            HStack(spacing: 10) {
                Menu {
                    ForEach(StepKind.allCases) { other in
                        Button { onChange(other.makeStep(macros: macroNames)) } label: { Label(other.title, systemImage: other.icon) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text(kind.title).font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 7, weight: .bold)).opacity(hovering ? 0.8 : 0)
                    }
                    .foregroundStyle(Theme.secondary)
                    .contentShape(Rectangle())
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
                .frame(width: 78, alignment: .leading)
                .help("Change what kind of step this is")

                StepValueEditor(step: step, macroNames: macroNames, profileNames: profileNames, onChange: onChange)
                if kind == .down {
                    Text("kept down until you let go of the button")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                HStack(spacing: 0) {
                    IconButton(symbol: "arrow.up", help: "Move up") { onMove(-1) }.disabled(index == 0)
                    IconButton(symbol: "arrow.down", help: "Move down") { onMove(1) }.disabled(index == count - 1)
                    IconButton(symbol: "plus.square.on.square", help: "Duplicate", action: onDuplicate)
                    IconButton(symbol: "xmark", help: "Remove", action: onDelete)
                }
                .opacity(hovering ? 1 : 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, isPause ? 5 : 8)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(isPause ? Color.clear : (hovering ? Theme.raised : Theme.surface)))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(isPause ? Color.clear : Theme.stroke))
            .padding(.vertical, 3)
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
