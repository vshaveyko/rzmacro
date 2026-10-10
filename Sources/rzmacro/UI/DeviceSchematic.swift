import SwiftUI

/// A drawing of a device with its special buttons clickable. It is built from the profile's
/// button list — a column of macro keys, a volume roller, a thumb grid — so it fits any model
/// that has those, and it glows with the current lighting effect.
struct DeviceSchematic: View {
    let kind: DeviceKind
    let keys: [DeviceKey]
    /// Buttons per row in a mouse's thumb grid.
    let gridColumns: Int
    let lighting: LightSpec?
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
        case .keyboard: return keys.contains { $0.group == "Macro keys" || $0.group == "Volume roller" }
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
        return ZStack(alignment: .topLeading) {
            Canvas { context, _ in
                let gap = 0.07 * scale
                func rect(_ unit: CGRect) -> CGRect {
                    CGRect(x: unit.minX * scale, y: unit.minY * scale, width: unit.width * scale, height: unit.height * scale).insetBy(dx: gap, dy: gap)
                }
                // Underglow first, blurred, then the key caps on top of it.
                context.drawLayer { layer in
                    layer.addFilter(.blur(radius: scale * 0.16))
                    for key in layout.keys {
                        let color = led(Double(key.midX / KeyboardLayout.size.width) * 0.8, time)
                        layer.fill(Path(roundedRect: rect(key).insetBy(dx: -gap, dy: -gap), cornerRadius: scale * 0.2), with: .color(color.opacity(0.75)))
                    }
                }
                for key in layout.keys {
                    context.fill(Path(roundedRect: rect(key), cornerRadius: scale * 0.17), with: .color(Color(rgb: 0x20242D)))
                    context.stroke(Path(roundedRect: rect(key), cornerRadius: scale * 0.17), with: .color(Color.white.opacity(0.07)), lineWidth: 0.5)
                }
            }
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
        }
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

    /// The ordinary keys, drawn but not clickable.
    let keys: [CGRect]
    let macros: [CGRect]
    let roller: CGRect

    init(macroKeys: Int, hasRoller: Bool) {
        func rowY(_ row: Int) -> CGFloat { row == 0 ? 0 : 0.5 + CGFloat(row) }
        /// Keys of the given widths side by side, starting at `x`.
        func run(_ widths: [CGFloat], x: CGFloat, row: Int) -> [CGRect] {
            var x = x
            return widths.map { width in
                defer { x += width }
                return CGRect(x: x, y: rowY(row), width: width, height: 1)
            }
        }
        let main: CGFloat = 1.6, nav = main + 15.5, pad = nav + 3.5
        var keys: [CGRect] = []
        // Function row: Esc, then three groups of four.
        keys += run([1], x: main, row: 0) + run([1, 1, 1, 1], x: main + 2, row: 0) + run([1, 1, 1, 1], x: main + 6.5, row: 0) + run([1, 1, 1, 1], x: main + 11, row: 0)
        keys += run(Array(repeating: 1, count: 13) + [2], x: main, row: 1)
        keys += run([1.5] + Array(repeating: 1, count: 12) + [1.5], x: main, row: 2)
        keys += run([1.75] + Array(repeating: 1, count: 11) + [2.25], x: main, row: 3)
        keys += run([2.25] + Array(repeating: 1, count: 10) + [2.75], x: main, row: 4)
        keys += run([1.25, 1.25, 1.25, 6.25, 1.25, 1.25, 1.25, 1.25], x: main, row: 5)
        // Navigation cluster and arrows.
        for row in [0, 1, 2, 5] { keys += run([1, 1, 1], x: nav, row: row) }
        keys += run([1], x: nav + 1, row: 4)
        // Number pad; the roller, if there is one, takes the place of the keys above it.
        if !hasRoller { keys += run([1, 1, 1, 1], x: pad, row: 0) }
        for row in 1...4 { keys += run([1, 1, 1, 1], x: pad, row: row) }
        keys += run([2, 1, 1], x: pad, row: 5)
        self.keys = keys

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
