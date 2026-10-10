import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// A physical button as the device pages present it.
struct DeviceKey: Identifiable {
    let trigger: Trigger
    let label: String
    /// Full name, where the group and label don't make one.
    var name: String?
    let group: String
    /// What it does when nothing is assigned.
    let defaultBehaviour: String
    var isMomentary = false
    var hotspot: CGRect?

    var id: Trigger { trigger }

    /// "Macro key M1", "Thumb button 7".
    var title: String {
        if let name { return name }
        switch group {
        case "Macro keys": return "Macro key \(label)"
        case "Thumb grid": return "Thumb button \(label)"
        case "Volume roller": return "Volume roller \(label == "▲" ? "up" : "down")"
        case "Other buttons": return "Button \(label)"
        default: return "\(group) \(label)"
        }
    }

    init(_ key: DeviceProfile.Key, kind: DeviceKind) {
        trigger = Trigger(kind: kind, source: key.source)
        label = key.label
        name = key.name
        group = key.group
        defaultBehaviour = key.defaultBehaviour
        isMomentary = key.isMomentary
        hotspot = key.hotspot
    }

    /// A button the profile doesn't list: one that was seen being pressed, or is in the config.
    init(unlisted trigger: Trigger) {
        self.trigger = trigger
        group = "Other buttons"
        switch trigger.source {
        case .raw(let code):
            label = String(format: "#%02X", code)
            defaultBehaviour = "Does nothing"
        case .key(let usage):
            let name = Keys.nameByUsage[usage] ?? String(format: "%02x", usage)
            label = Keys.symbols[name] ?? name.uppercased()
            defaultBehaviour = "Types “\(name)”"
        case .button(let bit):
            label = "B\(bit + 1)"
            defaultBehaviour = "Clicks"
        case .wheel(let up):
            label = up ? "▲" : "▼"
            defaultBehaviour = up ? "Scrolls up" : "Scrolls down"
        }
    }
}

struct DevicePage: View {
    @ObservedObject var model: AppModel
    let kind: DeviceKind

    private var device: Daemon.DeviceSummary? { model.device(kind) }
    private var deviceProfile: DeviceProfile { model.profile(for: kind) }
    private var keys: [DeviceKey] { model.keys(for: kind) }
    private var selected: Trigger? { model.selectedButton[kind].flatMap { chosen in keys.contains { $0.trigger == chosen } ? chosen : nil } ?? keys.first?.trigger }
    private var selectedKey: DeviceKey? { keys.first { $0.trigger == selected } }

    var body: some View {
        HStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if model.config.driverMode[kind] != true { driverModeWarning }
                    deviceMap
                    Text(footnote)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 28)
                .padding(.top, 18)
                .padding(.bottom, 28)
            }
            Rectangle().fill(Theme.stroke).frame(width: 1).padding(.top, -Theme.titleBarOverlap)
            Group {
                if let key = selectedKey {
                    AssignmentInspector(model: model, key: key, profile: model.appProfile)
                        .id(key.trigger.description + (model.appProfile ?? ""))
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "hand.tap").font(.system(size: 26)).foregroundStyle(Theme.tertiary)
                        Text("Press a button on the device").foregroundStyle(Theme.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 356)
            .background(Theme.sidebar.padding(.top, -Theme.titleBarOverlap))
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text(device?.name.replacingOccurrences(of: "Razer ", with: "") ?? (kind == .keyboard ? "Keyboard" : "Mouse"))
                    .font(.system(size: 24, weight: .bold))
                HStack(spacing: 6) {
                    if let device {
                        StatusChip(text: "Connected", color: Theme.good, dot: true)
                        if let firmware = device.firmware { StatusChip(text: "Firmware \(firmware)") }
                        StatusChip(text: device.inDriverMode ? "Driver mode" : "Normal mode", color: device.inDriverMode ? Theme.secondary : Theme.warning)
                    } else {
                        StatusChip(text: "Not connected", color: Theme.tertiary, dot: true)
                    }
                }
            }
            Spacer()
            profileMenu
        }
    }

    private var footnote: String {
        if deviceProfile.productID == nil {
            return "RZMacro has no layout for this model. Press its special buttons and they are listed here, ready to be assigned."
        }
        return "Tip: press a button on the device to jump straight to it. Buttons light up here while they are held."
    }

    private var driverModeWarning: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            Text(kind == .keyboard
                 ? "Driver mode is off, so the macro keys send nothing."
                 : "Driver mode is off, so the buttons do whatever is stored on the mouse.")
                .font(.system(size: 12.5))
            Spacer()
            Button("Turn On") { model.config.driverMode[kind] = true }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warning.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warning.opacity(0.35)))
    }

    // MARK: Picture and buttons

    private func effective(_ key: DeviceKey) -> (assignment: Assignment?, inherited: Bool) {
        if let own = model.assignment(for: key.trigger, profile: model.appProfile) { return (own, false) }
        guard model.appProfile != nil, let base = model.assignment(for: key.trigger, profile: nil) else { return (nil, false) }
        return (base, true)
    }

    private func tile(_ key: DeviceKey) -> some View {
        let (assignment, inherited) = effective(key)
        return ButtonTile(
            key: key, assignment: assignment, inherited: inherited,
            isSelected: selected == key.trigger,
            isPressed: model.pressed.contains(key.trigger),
            isHovered: model.hoveredButton == key.trigger
        )
        .onTapGesture { model.selectedButton[kind] = key.trigger }
        .onHover { model.hoveredButton = $0 ? key.trigger : (model.hoveredButton == key.trigger ? nil : model.hoveredButton) }
    }

    /// The buttons as tiles, under one heading per group.
    private var tiles: some View {
        let groups = keys.reduce(into: [String]()) { if !$0.contains($1.group) { $0.append($1.group) } }
        let columns = deviceProfile.listColumns.map { Array(repeating: GridItem(.flexible(), spacing: 8), count: $0) }
            ?? [GridItem(.adaptive(minimum: 82), spacing: 8)]
        return VStack(alignment: .leading, spacing: 16) {
            ForEach(groups, id: \.self) { group in
                VStack(alignment: .leading, spacing: 8) {
                    SectionLabel(group)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                        ForEach(keys.filter { $0.group == group }) { tile($0) }
                    }
                }
            }
        }
    }

    /// The device with its buttons clickable: the product photo if the user has asked for it,
    /// otherwise a drawing, with a switch between the two in the corner.
    @ViewBuilder private var stage: some View {
        let summary: (DeviceKey) -> String = { key in effective(key).assignment?.summary ?? key.defaultBehaviour }
        let isAssigned: (DeviceKey) -> Bool = { effective($0).assignment != nil }
        if let picture = deviceProfile.picture, let image = model.photo(for: picture) {
            DeviceStage(
                image: image, picture: picture, keys: keys.filter { $0.hotspot != nil },
                selected: selected, pressed: model.pressed, hovered: model.hoveredButton,
                summary: summary, isAssigned: isAssigned,
                onHover: { model.hoveredButton = $0 },
                onSelect: { model.selectedButton[kind] = $0 })
            .overlay(alignment: .bottomTrailing) { pictureSwitch }
        } else {
            DeviceSchematic(
                kind: kind, keys: keys, gridColumns: deviceProfile.listColumns ?? 3, lighting: model.config.lighting,
                selected: selected, pressed: model.pressed, hovered: model.hoveredButton,
                summary: summary, isAssigned: isAssigned,
                onHover: { model.hoveredButton = $0 },
                onSelect: { model.selectedButton[kind] = $0 })
            .padding(kind == .keyboard ? 22 : 18)
            .frame(maxWidth: .infinity)
            .background(RadialGradient(colors: [Color(rgb: 0x2C3140), Color(rgb: 0x171A21)], center: .center, startRadius: 0, endRadius: 360))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
            .overlay(alignment: .bottomTrailing) { pictureSwitch }
        }
    }

    /// Drawing or photo. The photo is the manufacturer's, fetched from their site on request.
    @ViewBuilder private var pictureSwitch: some View {
        if let picture = deviceProfile.picture {
            let showingPhoto = model.photo(for: picture) != nil
            Button {
                if showingPhoto { model.showsPhotos = false } else { model.usePhoto(picture) }
            } label: {
                HStack(spacing: 5) {
                    if model.isDownloadingPhoto {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: showingPhoto ? "pencil.and.outline" : "photo").font(.system(size: 10, weight: .semibold))
                    }
                    Text(showingPhoto ? "Drawing" : "Photo").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.45)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(model.isDownloadingPhoto)
            .padding(10)
            .help(model.photoError.map { "Could not get the photo: \($0)" }
                  ?? (showingPhoto ? "Show the drawing instead" : "Show Razer's product photo of this model (downloaded from razer.com the first time)"))
        }
    }

    @ViewBuilder private var deviceMap: some View {
        let hasPhoto = deviceProfile.picture.flatMap { model.photo(for: $0) } != nil
        if hasPhoto || DeviceSchematic.canDraw(kind: kind, keys: keys) {
            if kind == .keyboard {
                // Wide: the device across the top, the buttons underneath.
                VStack(alignment: .leading, spacing: 20) {
                    stage
                    tiles
                }
            } else {
                // Tall: the device beside the buttons.
                HStack(alignment: .top, spacing: 18) {
                    stage.frame(width: 268)
                    tiles
                }
            }
        } else if keys.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "hand.tap").font(.system(size: 30)).foregroundStyle(Theme.tertiary)
                Text("Press a special button on the device").font(.system(size: 14, weight: .medium))
                Text("Macro keys and extra mouse buttons show up here the first time they are pressed.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 60)
            .panel()
        } else {
            tiles
        }
    }

    // MARK: App profiles

    private var profileMenu: some View {
        Menu {
            Button { model.appProfile = nil } label: { Label("All apps", systemImage: model.appProfile == nil ? "checkmark" : "square.grid.2x2") }
            if !model.config.apps.isEmpty {
                Divider()
                ForEach(model.config.apps.keys.sorted(), id: \.self) { bundleID in
                    Button { model.appProfile = bundleID } label: {
                        Label(AppModel.appName(bundleID), systemImage: model.appProfile == bundleID ? "checkmark" : "app")
                    }
                }
            }
            Divider()
            Menu("New profile for…") {
                ForEach(runningApps, id: \.self) { bundleID in
                    Button(AppModel.appName(bundleID)) { addProfile(bundleID) }
                }
                Divider()
                Button("Choose an app…") { chooseApp() }
            }
            if let profile = model.appProfile {
                Button("Delete the \(AppModel.appName(profile)) profile", role: .destructive) {
                    model.config.apps[profile] = nil
                    model.appProfile = nil
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: model.appProfile == nil ? "square.grid.2x2.fill" : "app.fill").font(.system(size: 11))
                Text(model.appProfile.map(AppModel.appName) ?? "All apps").font(.system(size: 12.5, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.tertiary)
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(model.appProfile == nil ? Color.white.opacity(0.08) : Theme.accent.opacity(0.3)))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Buttons can do different things per app. A profile only overrides the buttons you change in it.")
    }

    private var runningApps: [String] {
        let ids = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap(\.bundleIdentifier)
            .filter { $0 != Bundle.main.bundleIdentifier && model.config.apps[$0] == nil }
        return Array(Set(ids)).sorted { AppModel.appName($0).localizedCaseInsensitiveCompare(AppModel.appName($1)) == .orderedAscending }
    }

    private func addProfile(_ bundleID: String) {
        if model.config.apps[bundleID] == nil { model.config.apps[bundleID] = [:] }
        model.appProfile = bundleID
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundleID = Bundle(url: url)?.bundleIdentifier else { return }
        addProfile(bundleID)
    }
}

/// A small capsule of status text.
struct StatusChip: View {
    let text: String
    var color: Color = Theme.secondary
    var dot = false

    var body: some View {
        HStack(spacing: 5) {
            if dot { Circle().fill(color).frame(width: 6, height: 6) }
            Text(text).font(.system(size: 11, weight: .medium)).foregroundStyle(dot ? Theme.secondary : color)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }
}

/// One button in the list: its name, what it does, and whether it is being held.
struct ButtonTile: View {
    let key: DeviceKey
    let assignment: Assignment?
    /// The assignment comes from "All apps", not from the profile being edited.
    let inherited: Bool
    let isSelected: Bool
    let isPressed: Bool
    let isHovered: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(key.label).font(.system(size: 15, weight: .bold, design: .rounded)).lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 2)
                Image(systemName: assignment?.icon ?? "circle.dotted")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(assignment == nil ? Theme.tertiary : (inherited ? Theme.secondary : Theme.accent))
            }
            Text(assignment?.summary ?? key.defaultBehaviour)
                .font(.system(size: 11, weight: assignment == nil ? .regular : .medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .foregroundStyle(assignment == nil ? Theme.tertiary : (inherited ? Theme.secondary : Theme.text))
                .frame(maxWidth: .infinity, minHeight: 27, alignment: .topLeading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(isPressed ? Theme.accent.opacity(0.5) : (isSelected ? Theme.accent.opacity(0.17) : (isHovered ? Theme.raised : Theme.surface)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(isSelected ? Theme.accent : (isHovered ? Theme.strokeStrong : Theme.stroke), lineWidth: isSelected ? 1.5 : 1)
        )
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.12), value: isPressed)
    }
}

/// The manufacturer's product photo on a spotlit stage, with the special buttons clickable.
struct DeviceStage: View {
    let image: NSImage
    let picture: DeviceProfile.Picture
    let keys: [DeviceKey]
    let selected: Trigger?
    let pressed: Set<Trigger>
    let hovered: Trigger?
    let summary: (DeviceKey) -> String
    let isAssigned: (DeviceKey) -> Bool
    let onHover: (Trigger?) -> Void
    let onSelect: (Trigger) -> Void

    private static var cache: [String: NSImage] = [:]
    private static let inset: CGFloat = 18

    /// A product photo the user has downloaded; nil if they have not.
    static func image(named file: String) -> NSImage? {
        if let cached = cache[file] { return cached }
        guard let image = NSImage(contentsOf: Paths.pictures.appendingPathComponent(file)), let pixels = image.representations.first else { return nil }
        // Hotspots are in pixels: make points and pixels the same thing.
        image.size = NSSize(width: pixels.pixelsWide, height: pixels.pixelsHigh)
        cache[file] = image
        return image
    }

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / picture.crop.width
            ZStack(alignment: .topLeading) {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: image.size.width * scale, height: image.size.height * scale)
                    .offset(x: -picture.crop.minX * scale, y: -picture.crop.minY * scale)
                    .shadow(color: .black.opacity(0.55), radius: 14, y: 10)
                ForEach(keys) { key in
                    if let spot = key.hotspot { hotspot(key, spot, scale) }
                }
                if let key = keys.first(where: { $0.trigger == hovered }), let spot = key.hotspot {
                    callout(key, spot, scale, in: geometry.size)
                }
            }
            .frame(width: geometry.size.width, height: picture.crop.height * scale, alignment: .topLeading)
        }
        .aspectRatio(picture.crop.width / picture.crop.height, contentMode: .fit)
        .padding(.horizontal, Self.inset)
        .padding(.top, Self.inset)
        .padding(.bottom, picture.fadesOut ? 0 : Self.inset)
        // The devices are black: a soft spotlight behind them lets the outline read.
        .background(
            RadialGradient(colors: [Color(rgb: 0x5A6276), Color(rgb: 0x2A2E3A), Color(rgb: 0x191C23)], center: .center, startRadius: 0, endRadius: 330)
        )
        // Pictures cropped short of the device's far end fade out rather than stop.
        .overlay(alignment: .bottom) {
            LinearGradient(colors: [Color(rgb: 0x191C23).opacity(0), Color(rgb: 0x191C23)], startPoint: .top, endPoint: .bottom)
                .frame(height: picture.fadesOut ? 70 : 0)
                .allowsHitTesting(false)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.stroke))
    }

    private func hotspot(_ key: DeviceKey, _ spot: CGRect, _ scale: CGFloat) -> some View {
        let isSelected = selected == key.trigger
        let isPressed = pressed.contains(key.trigger)
        let isHovered = hovered == key.trigger
        let assigned = isAssigned(key)
        let radius = min(spot.width, spot.height) * scale * 0.24
        let fill: Color = isPressed ? Theme.accent.opacity(0.9) : (isSelected ? Theme.accent.opacity(0.45) : (isHovered ? Color.white.opacity(0.28) : (assigned ? Theme.accent.opacity(0.18) : Color.white.opacity(0.001))))
        // Quiet until needed: the picture already shows where the buttons are.
        let stroke: Color = isSelected || isHovered ? Color.white : (assigned ? Theme.accent.opacity(0.85) : Color.white.opacity(0.28))
        return RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(stroke, lineWidth: isSelected ? 2 : 1.2))
            .shadow(color: isSelected || isPressed ? Theme.accent : .clear, radius: 7)
            .frame(width: spot.width * scale, height: spot.height * scale)
            .contentShape(Rectangle())
            .onHover { onHover($0 ? key.trigger : (hovered == key.trigger ? nil : hovered)) }
            .onTapGesture { onSelect(key.trigger) }
            .position(x: (spot.midX - picture.crop.minX) * scale, y: (spot.midY - picture.crop.minY) * scale)
            .animation(.easeOut(duration: 0.12), value: isPressed)
    }

    /// A small label naming the hovered button and what it does.
    private func callout(_ key: DeviceKey, _ spot: CGRect, _ scale: CGFloat, in size: CGSize) -> some View {
        let x = (spot.midX - picture.crop.minX) * scale
        let y = (spot.minY - picture.crop.minY) * scale
        return HStack(spacing: 6) {
            Text(key.label).font(.system(size: 11, weight: .bold, design: .rounded))
            Text(summary(key)).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(Color.black.opacity(0.85)))
        .overlay(Capsule().strokeBorder(Theme.strokeStrong))
        .fixedSize()
        // Above the button, or below it when there is no room; kept inside the stage sideways.
        .position(x: min(max(x, 60), size.width - 60), y: y > 26 ? y - 16 : y + spot.height * scale + 16)
        .allowsHitTesting(false)
    }
}
