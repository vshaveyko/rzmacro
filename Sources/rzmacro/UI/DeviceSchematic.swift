import SwiftUI

/// A drawing of a device with its buttons clickable. It is built from the profile's button
/// list — a column of macro keys, a volume roller, a thumb grid — so it fits any model that
/// has those, and it glows with the current lighting effect. A keyboard's ordinary keys are
/// clickable too: any of them can be given something else to do.
struct DeviceSchematic: View {
    let kind: DeviceKind
    let keys: [DeviceKey]
    /// Buttons per row in a mouse's thumb grid.
    let gridColumns: Int
    let lighting: LightSpec?
    /// What the keyboard's ordinary keys have been given to do, by usage.
    var remapped: [UInt8: Assignment] = [:]
    let selected: Trigger?
    let pressed: Set<Trigger>
    let hovered: Trigger?
    let summary: (DeviceKey) -> String
    let isAssigned: (DeviceKey) -> Bool
    let onHover: (Trigger?) -> Void
    let onSelect: (Trigger) -> Void

    private var macroKeys: [DeviceKey] { keys.filter { $0.group == "Macro keys" } }
    private var rollerKeys: [DeviceKey] { keys.filter { $0.group == "Volume roller" } }
    private var thumbKeys: [DeviceKey] { keys.filter { $0.group == "Thumb grid" } }

    private func key(_ source: KeySource) -> DeviceKey? { keys.first { $0.trigger.source == source } }

    /// Whether there is anything to draw for these buttons.
    static func canDraw(kind: DeviceKind, keys: [DeviceKey]) -> Bool {
        switch kind {
        // Every keyboard has ordinary keys to click on.
        case .keyboard: return true
        case .mouse: return keys.contains { $0.group == "Thumb grid" }
        }
    }

    static func aspectRatio(kind: DeviceKind) -> CGFloat {
        kind == .keyboard ? KeyboardLayout.size.width / KeyboardLayout.size.height : MouseLayout.size.width / MouseLayout.size.height
    }

    var body: some View {
        // The glow follows the lighting effect; a few frames a second is plenty for a picture.
        TimelineView(.periodic(from: .now, by: lighting?.effect.isAnimated == true ? 1.0 / 12 : 3600)) { context in
            let time = context.date.timeIntervalSince(LightingController.epoch)
            GeometryReader { geometry in
                switch kind {
                case .keyboard: keyboard(scale: geometry.size.width / KeyboardLayout.size.width, time: time)
                case .mouse: mouse(scale: geometry.size.width / MouseLayout.size.width, time: time)
                }
            }
        }
        .aspectRatio(Self.aspectRatio(kind: kind), contentMode: .fit)
    }

    /// The colour an LED at `position` (0…1 across all devices) shows right now.
    private func led(_ position: Double, _ time: Double) -> Color {
        guard let lighting else { return Color.white.opacity(0.35) }
        return lighting.effect.color(x: position, time: time).scaled(max(lighting.brightness, 0.25)).color
    }

    // MARK: Keyboard

    private func keyboard(scale: CGFloat, time: Double) -> some View {
        let layout = KeyboardLayout(macroKeys: macroKeys.count, hasRoller: !rollerKeys.isEmpty)
        let gap = 0.07 * scale
        func rect(_ unit: CGRect) -> CGRect {
            CGRect(x: unit.minX * scale, y: unit.minY * scale, width: unit.width * scale, height: unit.height * scale).insetBy(dx: gap, dy: gap)
        }
        /// The ordinary key drawn at a point.
        func key(at point: CGPoint) -> Trigger? {
            let unit = CGPoint(x: point.x / scale, y: point.y / scale)
            return layout.caps.first { $0.usage != nil && $0.rect.contains(unit) }?.trigger
        }
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                // Underglow first, blurred, then the key caps on top of it.
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: scale * 0.16))
                    for cap in layout.caps {
                        let color = led(Double(cap.rect.midX / KeyboardLayout.size.width) * 0.8, time)
                        layer.fill(Path(roundedRect: rect(cap.rect).insetBy(dx: -gap, dy: -gap), cornerRadius: scale * 0.2), with: .color(color.opacity(0.75)))
                    }
                }
                for cap in layout.caps {
                    let assignment = cap.usage.flatMap { remapped[$0] }
                    let isSelected = cap.trigger != nil && cap.trigger == selected
                    let isHovered = cap.trigger != nil && cap.trigger == hovered
                    let isPressed = cap.trigger.map(pressed.contains) ?? false
                    var fill = Color(rgb: 0x20242D)
                    if isPressed { fill = Theme.accent } else if isSelected { fill = Theme.accent.opacity(0.6) } else if isHovered { fill = Color(rgb: 0x3D4354) } else if assignment != nil { fill = Color(rgb: 0x2E2B52) }
                    var stroke = Color.white.opacity(0.07), width: CGFloat = 0.5
                    if isSelected || isHovered { stroke = .white; width = isSelected ? 1.5 : 1 } else if assignment != nil { stroke = Theme.accent; width = 1 }
                    let frame = rect(cap.rect)
                    let path = Path(roundedRect: frame, cornerRadius: scale * 0.17)
                    context.fill(path, with: .color(fill))
                    context.stroke(path, with: .color(stroke), lineWidth: width)

                    // A key that has become another key says which; otherwise what is printed on it.
                    let legend = Self.legend(cap.legend, assignment)
                    let size = min(frame.height * 0.44, frame.width / (CGFloat(max(legend.count, 1)) * 0.62 + 0.4), 13)
                    let lit = assignment != nil || isSelected || isPressed
                    context.draw(
                        Text(legend).font(.system(size: size, weight: .semibold, design: .rounded)).foregroundColor(Color.white.opacity(lit ? 1 : (cap.usage == nil ? 0.3 : 0.6))),
                        at: CGPoint(x: frame.midX, y: frame.midY))
                }
            }
            // One hit area for all the ordinary keys: a hundred views would be a lot to keep
            // redrawing while the lighting animates.
            Color.clear
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    var under: Trigger?
                    if case .active(let point) = phase { under = key(at: point) }
                    // Off the keys, only an ordinary key's highlight is ours to clear.
                    if under != hovered, under != nil || hovered?.isOrdinaryKey == true { onHover(under) }
                }
                .gesture(SpatialTapGesture().onEnded { tap in
                    if let trigger = key(at: tap.location) { onSelect(trigger) }
                })
            ForEach(Array(macroKeys.enumerated()), id: \.element.id) { index, key in
                if let unit = layout.macros[safe: index] {
                    button(key, unit: unit, scale: scale, led: led(0, time))
                }
            }
            ForEach(Array(rollerKeys.enumerated()), id: \.element.id) { index, key in
                // The roller, split in two: one half per direction.
                let half = layout.roller.width / CGFloat(rollerKeys.count)
                let unit = CGRect(x: layout.roller.minX + half * CGFloat(index), y: layout.roller.minY, width: half, height: layout.roller.height)
                button(key, unit: unit, scale: scale, led: led(0.75, time))
            }
            if let cap = layout.caps.first(where: { $0.trigger != nil && $0.trigger == hovered }), let usage = cap.usage {
                callout(KeyboardKeys.byUsage[usage]?.title ?? cap.legend, remapped[usage]?.summary ?? "click to change", over: rect(cap.rect), width: KeyboardLayout.size.width * scale)
            }
        }
    }

    private static func legend(_ printed: String, _ assignment: Assignment?) -> String {
        guard let assignment else { return printed }
        if assignment.steps.isEmpty { return "⊘" }
        if assignment.steps.count == 1, case .tap(let chord) = assignment.steps[0] {
            let keys = chord.display.trimmingCharacters(in: .whitespaces)
            if keys.count <= 3 { return keys }
        }
        return printed
    }

    /// A small label naming the hovered key and what it does, above it (or below, at the top edge).
    private func callout(_ title: String, _ detail: String, over frame: CGRect, width: CGFloat) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 11, weight: .bold, design: .rounded))
            Text(detail).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.88)))
        .overlay(Capsule().strokeBorder(Theme.strokeStrong))
        .fixedSize()
        .position(x: min(max(frame.midX, 70), width - 70), y: frame.minY > 30 ? frame.minY - 15 : frame.maxY + 15)
        .allowsHitTesting(false)
    }

    // MARK: Mouse

    private func mouse(scale: CGFloat, time: Double) -> some View {
        let layout = MouseLayout(buttons: thumbKeys.count, columns: max(gridColumns, 1))
        func scaled(_ unit: CGRect) -> CGRect {
            CGRect(x: unit.minX * scale, y: unit.minY * scale, width: unit.width * scale, height: unit.height * scale)
        }
        let wheel = led(0.97, time)
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                // Cable, body, the two main buttons, the wheel.
                var cable = Path()
                cable.move(to: CGPoint(x: MouseLayout.body.midX * scale, y: 0))
                cable.addLine(to: CGPoint(x: MouseLayout.body.midX * scale, y: MouseLayout.body.minY * scale))
                context.stroke(cable, with: .color(Color(rgb: 0x2B303B)), lineWidth: scale * 0.28)

                let body = Path(roundedRect: scaled(MouseLayout.body), cornerSize: CGSize(width: scale * 3.1, height: scale * 3.9))
                context.fill(body, with: .linearGradient(
                    Gradient(colors: [Color(rgb: 0x353B48), Color(rgb: 0x1B1E26)]),
                    startPoint: CGPoint(x: 0, y: MouseLayout.body.minY * scale), endPoint: CGPoint(x: 0, y: MouseLayout.body.maxY * scale)))
                context.stroke(body, with: .color(Color.white.opacity(0.10)), lineWidth: 1)

                var split = Path()
                split.move(to: CGPoint(x: MouseLayout.body.midX * scale, y: MouseLayout.body.minY * scale))
                split.addLine(to: CGPoint(x: MouseLayout.body.midX * scale, y: (MouseLayout.body.minY + 5.6) * scale))
                context.stroke(split, with: .color(Color.black.opacity(0.55)), lineWidth: 1.2)

                let wheelRect = scaled(MouseLayout.wheel)
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: scale * 0.35))
                    layer.fill(Path(roundedRect: wheelRect.insetBy(dx: -scale * 0.12, dy: -scale * 0.12), cornerRadius: wheelRect.width), with: .color(wheel.opacity(0.9)))
                }
                context.fill(Path(roundedRect: wheelRect, cornerRadius: wheelRect.width / 2), with: .color(Color(rgb: 0x12141A)))
                context.stroke(Path(roundedRect: wheelRect, cornerRadius: wheelRect.width / 2), with: .color(wheel), lineWidth: 1.5)

                // The thumb panel the grid sits on.
                let panel = Path(roundedRect: scaled(layout.panel), cornerRadius: scale * 0.75)
                context.fill(panel, with: .color(Color(rgb: 0x262B36)))
                context.stroke(panel, with: .color(Color.white.opacity(0.10)), lineWidth: 1)
            }
            ForEach(Array(thumbKeys.enumerated()), id: \.element.id) { index, key in
                if let unit = layout.buttons[safe: index] {
                    button(key, unit: unit, scale: scale, led: led(0.92, time))
                }
            }
            // The ordinary controls: right button, the wheel as a button, and its two directions.
            if let right = key(.button(1)) { zone(right, unit: MouseLayout.rightButton, scale: scale, capsule: false, label: "Right") }
            if let click = key(.button(2)) { zone(click, unit: MouseLayout.wheel, scale: scale, capsule: true, label: "") }
            if let up = key(.wheel(up: true)) { button(up, unit: MouseLayout.wheelUp, scale: scale, led: wheel) }
            if let down = key(.wheel(up: false)) { button(down, unit: MouseLayout.wheelDown, scale: scale, led: wheel) }
        }
    }

    /// A clickable part of the device that is not a key: it keeps the drawing underneath and
    /// only shows an outline when it has something to say.
    private func zone(_ key: DeviceKey, unit: CGRect, scale: CGFloat, capsule: Bool, label: String) -> some View {
        let isSelected = selected == key.trigger
        let isPressed = pressed.contains(key.trigger)
        let isHovered = hovered == key.trigger
        let assigned = isAssigned(key)
        let width = unit.width * scale, height = unit.height * scale
        let radius = capsule ? width / 2 : scale * 0.5
        var fill = Color.white.opacity(0.001)
        if isPressed { fill = Theme.accent.opacity(0.85) } else if isSelected { fill = Theme.accent.opacity(0.4) } else if isHovered { fill = Color.white.opacity(0.14) } else if assigned { fill = Theme.accent.opacity(0.16) }
        var stroke = Color.clear
        if isSelected || isHovered { stroke = .white } else if assigned { stroke = Theme.accent }
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: isSelected ? 2 : 1))
            .overlay(Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.white.opacity(isSelected || assigned ? 0.95 : 0.4)))
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onHover { onHover($0 ? key.trigger : (hovered == key.trigger ? nil : hovered)) }
            .onTapGesture { onSelect(key.trigger) }
            .help("\(key.title): \(summary(key))")
            .position(x: unit.midX * scale, y: unit.midY * scale)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }

    // MARK: Buttons

    /// A clickable button of the device, drawn as a key cap with its label lit like the LEDs.
    private func button(_ key: DeviceKey, unit: CGRect, scale: CGFloat, led: Color) -> some View {
        let isSelected = selected == key.trigger
        let isPressed = pressed.contains(key.trigger)
        let isHovered = hovered == key.trigger
        let assigned = isAssigned(key)
        let gap = 0.07 * scale
        let width = unit.width * scale - gap * 2
        let height = unit.height * scale - gap * 2
        let radius = min(width, height) * 0.22
        let lit = isSelected || isPressed
        var fill = Color(rgb: 0x333948)
        if isPressed { fill = Theme.accent } else if isSelected { fill = Theme.accent.opacity(0.55) } else if isHovered { fill = Color(rgb: 0x4A5163) }
        // Lit like the LEDs around it unless there is something to say: selected, or assigned.
        var stroke = led.opacity(0.7)
        if isSelected || isHovered { stroke = .white } else if assigned { stroke = Theme.accent }
        let fontSize = min(width * 0.5, height * 0.52)
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: isSelected ? 2 : 1))
            .overlay(
                Text(key.label)
                    .font(.system(size: fontSize, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .foregroundStyle(Color.white.opacity(lit || assigned ? 1 : 0.8))
                    .padding(1)
            )
            .shadow(color: lit ? Theme.accent.opacity(0.9) : led.opacity(0.35), radius: lit ? 7 : 3)
            .frame(width: width, height: height)
            .contentShape(Rectangle())
            .onHover { onHover($0 ? key.trigger : (hovered == key.trigger ? nil : hovered)) }
            .onTapGesture { onSelect(key.trigger) }
            .help("\(key.title): \(summary(key))")
            .position(x: unit.midX * scale, y: unit.midY * scale)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

/// Where everything on a full-size keyboard goes, in key units (one unit = one ordinary key).
private struct KeyboardLayout {
    /// Macro column, main block, navigation cluster, number pad; six rows with a gap under the top one.
    static let size = CGSize(width: 24.6, height: 6.5)

    struct Cap {
        let rect: CGRect
        /// nil for a key that is drawn but can't be assigned: Fn belongs to the keyboard itself.
        let usage: UInt8?
        let legend: String

        var trigger: Trigger? { usage.map { Trigger(kind: .keyboard, source: .key($0)) } }
    }

    let caps: [Cap]
    let macros: [CGRect]
    let roller: CGRect

    init(macroKeys: Int, hasRoller: Bool) {
        func rowY(_ row: Int) -> CGFloat { row == 0 ? 0 : 0.5 + CGFloat(row) }
        var caps: [Cap] = []
        /// Keys side by side, starting at `x`: each a name from `KeyboardKeys`, with "*1.5" for
        /// one that is wider than a unit. A name that is no key is drawn with that as its legend.
        func run(_ keys: [String], x: CGFloat, row: Int, height: CGFloat = 1) {
            var x = x
            for spec in keys {
                let parts = spec.components(separatedBy: "*")
                let width = parts.count > 1 ? CGFloat(Double(parts[1]) ?? 1) : 1
                let key = KeyboardKeys.byName[parts[0]]
                caps.append(Cap(rect: CGRect(x: x, y: rowY(row), width: width, height: height), usage: key?.usage, legend: key?.legend ?? parts[0]))
                x += width
            }
        }
        let main: CGFloat = 1.6, nav = main + 15.5, pad = nav + 3.5
        // Function row: Esc, then three groups of four.
        run(["escape"], x: main, row: 0)
        run(["f1", "f2", "f3", "f4"], x: main + 2, row: 0)
        run(["f5", "f6", "f7", "f8"], x: main + 6.5, row: 0)
        run(["f9", "f10", "f11", "f12"], x: main + 11, row: 0)
        run(["grave", "1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "minus", "equal", "delete*2"], x: main, row: 1)
        run(["tab*1.5", "q", "w", "e", "r", "t", "y", "u", "i", "o", "p", "leftbracket", "rightbracket", "backslash*1.5"], x: main, row: 2)
        run(["capslock*1.75", "a", "s", "d", "f", "g", "h", "j", "k", "l", "semicolon", "quote", "return*2.25"], x: main, row: 3)
        run(["left-shift*2.25", "z", "x", "c", "v", "b", "n", "m", "comma", "period", "slash", "right-shift*2.75"], x: main, row: 4)
        run(["left-ctrl*1.25", "left-cmd*1.25", "left-alt*1.25", "space*6.25", "right-alt*1.25", "Fn*1.25", "menu*1.25", "right-ctrl*1.25"], x: main, row: 5)
        // Navigation cluster and arrows.
        run(["printscreen", "scrolllock", "pause"], x: nav, row: 0)
        run(["insert", "home", "pageup"], x: nav, row: 1)
        run(["forwarddelete", "end", "pagedown"], x: nav, row: 2)
        run(["up"], x: nav + 1, row: 4)
        run(["left", "down", "right"], x: nav, row: 5)
        // Number pad; the roller, if there is one, takes the place of the keys above it.
        if !hasRoller { run(["", "", "", ""], x: pad, row: 0) }
        run(["numlock", "kp-divide", "kp-multiply", "kp-minus"], x: pad, row: 1)
        run(["kp7", "kp8", "kp9"], x: pad, row: 2)
        run(["kp-plus"], x: pad + 3, row: 2, height: 2)
        run(["kp4", "kp5", "kp6"], x: pad, row: 3)
        run(["kp1", "kp2", "kp3"], x: pad, row: 4)
        run(["kp-enter"], x: pad + 3, row: 4, height: 2)
        run(["kp0*2", "kp-dot"], x: pad, row: 5)
        self.caps = caps

        // Six macro keys run down the whole left edge; fewer sit beside the main rows.
        let firstRow = macroKeys >= 6 ? 0 : 1
        macros = (0..<macroKeys).map { CGRect(x: 0, y: rowY(min(firstRow + $0, 5)), width: 1, height: 1) }
        roller = CGRect(x: pad + 0.5, y: 0.18, width: 3, height: 0.64)
    }
}

/// A mouse seen from above with its thumb grid on the left, in arbitrary units.
private struct MouseLayout {
    static let size = CGSize(width: 10, height: 14.6)
    static let body = CGRect(x: 3.1, y: 0.9, width: 6.5, height: 13.3)
    static let wheel = CGRect(x: 5.95, y: 2.75, width: 0.8, height: 2.0)
    static let wheelUp = CGRect(x: 5.85, y: 1.65, width: 1.0, height: 1.0)
    static let wheelDown = CGRect(x: 5.85, y: 4.85, width: 1.0, height: 1.0)
    static let rightButton = CGRect(x: 7.05, y: 2.2, width: 2.15, height: 3.0)

    let panel: CGRect
    let buttons: [CGRect]

    init(buttons count: Int, columns: Int) {
        let side: CGFloat = 1.25, gap: CGFloat = 0.12, margin: CGFloat = 0.3
        let rows = max((count + columns - 1) / columns, 1)
        let width = CGFloat(columns) * side + CGFloat(columns - 1) * gap
        let height = CGFloat(rows) * side + CGFloat(rows - 1) * gap
        // Overlapping the body's left edge, about where a thumb rests.
        let origin = CGPoint(x: 0.3, y: 6.3)
        panel = CGRect(x: origin.x, y: origin.y, width: width + margin * 2, height: height + margin * 2)
        buttons = (0..<count).map { index in
            CGRect(
                x: origin.x + margin + CGFloat(index % columns) * (side + gap),
                y: origin.y + margin + CGFloat(index / columns) * (side + gap),
                width: side, height: side)
        }
    }
}
