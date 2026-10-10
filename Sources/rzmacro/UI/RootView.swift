import SwiftUI

/// The window: navigation on the left, the chosen page on the right.
struct RootView: View {
    @ObservedObject var model: AppModel
    /// Height of the window's (transparent) title bar, which the content extends under.
    let titleBarHeight: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(model: model).frame(width: 220)
            Rectangle().fill(Theme.stroke).frame(width: 1)
            VStack(spacing: 0) {
                // Nothing that scrolls may start inside the title bar: macOS would treat it as
                // content scrolling under the bar and add its own edge effect.
                Color.clear.frame(height: titleBarHeight)
                PermissionBanner(model: model)
                Group {
                    switch model.page {
                    case .keyboard: DevicePage(model: model, kind: .keyboard)
                    case .mouse: DevicePage(model: model, kind: .mouse)
                    case .profiles: ProfilesPage(model: model)
                    case .macros: MacrosPage(model: model)
                    case .lighting: LightingPage(model: model)
                    case .settings: SettingsPage(model: model)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .background(Theme.window)
        }
        .frame(minWidth: 1120, minHeight: 700)
        .background(Theme.window)
        .foregroundStyle(Theme.text)
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
    }
}

/// Says so, loudly, when macOS is not letting the driver do its job.
private struct PermissionBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if !model.inputMonitoring {
            banner(
                "RZMacro can't see your devices' buttons",
                "macOS needs to allow it under Input Monitoring. RZMacro restarts by itself once it is switched on.",
                pane: "Privacy_ListenEvent")
        } else if !model.accessibility {
            banner(
                "RZMacro can't send keystrokes yet",
                "macOS needs to allow it under Accessibility before macros can type or press shortcuts.",
                pane: "Privacy_Accessibility")
        }
    }

    private func banner(_ title: String, _ detail: String, pane: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.trianglebadge.exclamationmark.fill")
                .font(.system(size: 18))
                .foregroundStyle(Theme.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button("Open System Settings") { openPrivacySettings(pane) }
                .buttonStyle(PillButtonStyle(kind: .primary, compact: true))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.warning.opacity(0.12))
        .overlay(Rectangle().fill(Theme.warning.opacity(0.4)).frame(height: 1), alignment: .bottom)
    }
}

private struct Sidebar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 9) {
                if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 26, height: 26)
                }
                Text("RZMacro").font(.system(size: 15, weight: .bold))
            }
            .padding(.horizontal, 10)
            .padding(.top, 46)
            .padding(.bottom, 18)

            SectionLabel("Devices").padding(.horizontal, 10).padding(.bottom, 4)
            deviceItem(.keyboard, page: .keyboard)
            deviceItem(.mouse, page: .mouse)

            SectionLabel("Library").padding(.horizontal, 10).padding(.top, 18).padding(.bottom, 4)
            SidebarItem(
                icon: "square.stack.3d.up.fill", title: "Profiles",
                // Which one is in use, once there is more than the default to be in use.
                detail: model.config.profiles.isEmpty ? nil : "In use: \(model.activeProfile ?? Profile.defaultName)",
                trailing: model.config.profiles.isEmpty ? nil : "\(model.config.profiles.count)",
                isSelected: model.page == .profiles
            ) { model.page = .profiles }
            SidebarItem(
                icon: "bolt.fill", title: "Macros", detail: nil,
                trailing: model.config.macros.isEmpty ? nil : "\(model.config.macros.count)",
                isSelected: model.page == .macros
            ) { model.page = .macros }
            SidebarItem(
                icon: "lightbulb.fill", title: "Lighting", detail: nil,
                trailing: model.config.lighting.map(\.kind.title) ?? "Off",
                isSelected: model.page == .lighting
            ) { model.page = .lighting }

            Spacer()
            SidebarItem(
                icon: "gearshape.fill", title: "Settings", detail: nil, trailing: nil,
                badge: !model.inputMonitoring || !model.accessibility || model.configError != nil,
                isSelected: model.page == .settings
            ) { model.page = .settings }
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 14)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }

    private func deviceItem(_ kind: DeviceKind, page: Page) -> some View {
        let device = model.device(kind)
        return SidebarItem(
            icon: kind == .keyboard ? "keyboard.fill" : "computermouse.fill",
            title: kind == .keyboard ? "Keyboard" : "Mouse",
            detail: device?.name.replacingOccurrences(of: "Razer ", with: "") ?? "Not connected",
            trailing: nil, status: device == nil ? Theme.tertiary : Theme.good,
            isSelected: model.page == page
        ) { model.page = page }
    }
}

private struct SidebarItem: View {
    let icon: String
    let title: String
    let detail: String?
    let trailing: String?
    var status: Color?
    var badge = false
    let isSelected: Bool
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.text : Theme.secondary)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(isSelected ? Theme.accent : Color.white.opacity(0.07)))
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(isSelected ? Theme.text : Theme.text.opacity(0.85))
                    if let detail {
                        Text(detail).font(.system(size: 10.5)).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if let trailing {
                    Text(trailing).font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                }
                if let status {
                    Circle().fill(status).frame(width: 7, height: 7)
                }
                if badge {
                    Image(systemName: "exclamationmark.circle.fill").font(.system(size: 13)).foregroundStyle(Theme.warning)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(isSelected ? Color.white.opacity(0.09) : (hovering ? Color.white.opacity(0.05) : Color.clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
