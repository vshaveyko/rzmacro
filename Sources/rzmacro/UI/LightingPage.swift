import SwiftUI

struct LightingPage: View {
    @ObservedObject var model: AppModel

    /// Colours survive a trip through an effect that has none (spectrum, wave).
    @State private var rememberedColors: [RGB] = [RGB(r: 0, g: 255, b: 102), RGB(r: 0, g: 128, b: 255)]

    private static let swatches = ["#ff2d2d", "#ff7a00", "#ffd000", "#00ff66", "#00e5ff", "#2d6bff", "#8b3dff", "#ff2d95", "#ffffff"].compactMap { try? RGB(parsing: $0) }

    private var spec: LightSpec? { model.config.lighting }

    /// Rebuilds the spec with some parts replaced.
    private func set(kind: LightSpec.Kind? = nil, colors: [RGB]? = nil, period: Double? = nil, reverse: Bool? = nil, brightness: Double? = nil) {
        let current = spec ?? Config.initial.lighting!
        let newKind = kind ?? current.kind
        var newColors = colors ?? (current.colors.isEmpty ? rememberedColors : current.colors)
        if newKind == .solid { newColors = Array(newColors.prefix(1)) }
        if !newColors.isEmpty { rememberedColors = newColors + rememberedColors.dropFirst(newColors.count) }
        model.config.lighting = LightSpec(
            kind: newKind, colors: newColors,
            // Each effect has its own natural speed; don't carry one over when switching.
            period: period ?? (kind == nil ? current.period : nil),
            reverse: reverse ?? current.reverse,
            brightness: brightness ?? current.brightness,
            fps: current.fps)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Lighting").font(.system(size: 24, weight: .bold))
                        Text("One effect across every device, driven from a single clock so they never drift apart.")
                            .font(.system(size: 12.5))
                            .foregroundStyle(Theme.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        Text(spec == nil ? "Off" : "On").font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.secondary)
                        Toggle("", isOn: Binding(get: { spec != nil }, set: { on in
                            if on { set() } else { model.config.lighting = nil }
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                    }
                    .help("Off: RZMacro leaves the lights alone and each device runs its own stored effect.")
                }

                if let spec {
                    LightPreview(spec: spec)
                    VStack(alignment: .leading, spacing: 8) {
                        SectionLabel("Effect")
                        HStack(spacing: 8) {
                            ForEach(LightSpec.Kind.allCases, id: \.self) { kind in
                                EffectTile(kind: kind, sample: sample(kind, from: spec), isSelected: spec.kind == kind) { set(kind: kind) }
                            }
                        }
                    }
                    if spec.kind != .off {
                        VStack(alignment: .leading, spacing: 8) {
                            SectionLabel("Settings")
                            VStack(alignment: .leading, spacing: 14) { controls(spec) }.panel()
                        }
                    }
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "lightbulb.slash").font(.system(size: 26)).foregroundStyle(Theme.tertiary)
                        Text("RZMacro is leaving the lights alone").font(.system(size: 14, weight: .medium))
                        Text("Each device runs whatever effect is stored on it, on its own clock.")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 50)
                    .panel()
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: 860, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What an effect tile shows: that effect with the current colours and brightness.
    private func sample(_ kind: LightSpec.Kind, from spec: LightSpec) -> LightSpec {
        LightSpec(kind: kind, colors: spec.colors.isEmpty ? rememberedColors : spec.colors, period: kind == spec.kind ? spec.period : nil, reverse: spec.reverse, brightness: 1)
    }

    @ViewBuilder private func controls(_ spec: LightSpec) -> some View {
        if spec.kind == .solid || spec.kind == .breathing {
            row("Colour") {
                HStack(spacing: 8) {
                    ForEach(Array(spec.colors.enumerated()), id: \.offset) { index, color in
                        ColorPicker("", selection: Binding(get: { color.color }, set: { new in
                            var colors = spec.colors
                            colors[index] = RGB(new)
                            set(colors: colors)
                        }), supportsOpacity: false)
                        .labelsHidden()
                    }
                    if spec.kind == .breathing {
                        IconButton(symbol: "plus", help: "Add a colour") {
                            set(colors: spec.colors + [rememberedColors[safe: spec.colors.count] ?? Self.swatches[spec.colors.count % Self.swatches.count]])
                        }
                        .disabled(spec.colors.count >= 4)
                        IconButton(symbol: "minus", help: "Remove the last colour") { set(colors: Array(spec.colors.dropLast())) }
                            .disabled(spec.colors.count <= 1)
                    }
                    Rectangle().fill(Theme.stroke).frame(width: 1, height: 20).padding(.horizontal, 4)
                    ForEach(Array(Self.swatches.enumerated()), id: \.offset) { _, swatch in
                        Circle()
                            .fill(swatch.color)
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(Color.white.opacity(spec.colors.first == swatch ? 0.9 : 0.2), lineWidth: spec.colors.first == swatch ? 2 : 1))
                            .onTapGesture { set(colors: [swatch] + spec.colors.dropFirst()) }
                    }
                }
            }
        }
        if let period = spec.period {
            row("Speed") {
                HStack(spacing: 10) {
                    Image(systemName: "tortoise.fill").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    // The slider runs slow-to-fast, the period the other way round.
                    Slider(value: Binding(get: { 30.5 - period }, set: { set(period: ((30.5 - $0) * 10).rounded() / 10) }), in: 0.5...30)
                    Image(systemName: "hare.fill").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                    Text(String(format: "%.1f s", period)).font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondary).frame(width: 48, alignment: .trailing)
                }
            }
        }
        if spec.kind == .wave {
            row("Direction") {
                Segmented(options: [(false, "Left to right"), (true, "Right to left")], selection: Binding(get: { spec.reverse }, set: { set(reverse: $0) }))
                    .frame(width: 260)
            }
        }
        row("Brightness") {
            HStack(spacing: 10) {
                Image(systemName: "sun.min.fill").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Slider(value: Binding(get: { spec.brightness }, set: { set(brightness: $0) }), in: 0...1)
                Image(systemName: "sun.max.fill").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                Text("\(Int((spec.brightness * 100).rounded()))%").font(.system(size: 12)).monospacedDigit().foregroundStyle(Theme.secondary).frame(width: 48, alignment: .trailing)
            }
        }
        Text("Fn+F11 and Fn+F12 on the keyboard dim and brighten everything together.")
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.tertiary)
    }

    private func row<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: 12.5)).foregroundStyle(Theme.secondary).frame(width: 78, alignment: .leading)
            content()
        }
    }
}

/// One effect to choose, showing itself in miniature.
private struct EffectTile: View {
    let kind: LightSpec.Kind
    /// The effect as it would look with the current colours.
    let sample: LightSpec
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 9) {
                TimelineView(.periodic(from: .now, by: sample.effect.isAnimated ? 1.0 / 20 : 3600)) { context in
                    let time = context.date.timeIntervalSince(LightingController.epoch)
                    HStack(spacing: 2) {
                        ForEach(0..<9, id: \.self) { index in
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .fill(kind == .off ? Color.white.opacity(0.07) : sample.effect.color(x: Double(index) / 8 * 0.8, time: time).color)
                        }
                    }
                    .frame(height: 22)
                }
                Text(kind.title).font(.system(size: 12, weight: .medium)).foregroundStyle(isSelected ? Theme.text : Theme.secondary)
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isSelected ? Theme.accent.opacity(0.20) : (hovering ? Theme.raised : Theme.surface)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(isSelected ? Theme.accent : Theme.stroke, lineWidth: isSelected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Draws what the LEDs are showing right now, from the same function and clock the driver uses.
private struct LightPreview: View {
    let spec: LightSpec

    private static let keyboard = DeviceProfile.preferred(for: .keyboard).lights.positions
    private static let mouse = DeviceProfile.preferred(for: .mouse).lights.positions

    var body: some View {
        TimelineView(.periodic(from: .now, by: spec.effect.isAnimated ? 1.0 / 24 : 3600)) { context in
            let time = context.date.timeIntervalSince(LightingController.epoch)
            HStack(alignment: .bottom, spacing: 26) {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(spacing: 4) {
                        ForEach(0..<5, id: \.self) { _ in
                            HStack(spacing: 4) {
                                ForEach(Array(Self.keyboard.enumerated()), id: \.offset) { _, x in cell(x, time).frame(height: 15) }
                            }
                        }
                    }
                    SectionLabel("Keyboard")
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 4) {
                        ForEach(Array(Self.mouse.enumerated()), id: \.offset) { _, x in cell(x, time).frame(width: 24, height: 91) }
                    }
                    SectionLabel("Mouse")
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black.opacity(0.45)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
        }
    }

    /// One LED: its colour, with a glow of the same colour so the strip looks lit rather than painted.
    private func cell(_ x: Double, _ time: Double) -> some View {
        let color = spec.effect.color(x: x, time: time).scaled(spec.brightness).color
        return RoundedRectangle(cornerRadius: 3.5, style: .continuous)
            .fill(color)
            .shadow(color: color.opacity(0.7), radius: 5)
    }
}
