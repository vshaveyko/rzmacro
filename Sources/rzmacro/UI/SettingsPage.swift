import AppKit
import SwiftUI

/// Opens a pane of System Settings > Privacy & Security.
func openPrivacySettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
}

struct SettingsPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Settings").font(.system(size: 24, weight: .bold))

                if let error = model.configError {
                    group("Configuration file") {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12.5)).foregroundStyle(Theme.danger)
                        Text("The file could not be read, so the previous settings are still in use. Changing anything in the app overwrites it.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.secondary)
                    }
                }

                group("Permissions") {
                    permission("Input Monitoring", "Lets RZMacro see the buttons you press on the devices.", granted: model.inputMonitoring, pane: "Privacy_ListenEvent")
                    separator
                    permission("Accessibility", "Lets it send keystrokes, and swallow the ones bound buttons type.", granted: model.accessibility, pane: "Privacy_Accessibility")
                }

                group("Devices") {
                    if model.devices.isEmpty {
                        Text("No Razer devices found.").font(.system(size: 12.5)).foregroundStyle(Theme.secondary)
                    }
                    ForEach(model.devices) { device in
                        deviceRow(device)
                        if device.id != model.devices.last?.id { separator }
                    }
                }

                group("Key presses") {
                    settingRow(
                        "How fast macros and shortcuts press keys",
                        "Instant sends presses back to back. With a delay, each key is held for that long and followed by the same pause, for games and remote desktops that miss very quick presses. Typed text is spaced the same way. A macro can have its own speed on the Macros page."
                    ) { EmptyView() }
                    KeySpeedControl(value: model.config.keyDelay) { model.config.keyDelay = $0 ?? 0 }
                }

                group("Profiles") {
                    settingRow(
                        "Show the profile's name on screen when it changes",
                        "A note at the top of the screen for a moment, over a game too — so you can tell which profile you just switched to, or that your hero's is on. With profiles for apps, “Always” also shows it every time you switch to one of those apps."
                    ) { EmptyView() }
                    Segmented(options: [(ProfileNotes.always, "Always"), (ProfileNotes.notApps, "By hand and for heroes"), (ProfileNotes.never, "Never")], selection: $model.config.profileNotes)
                        .frame(maxWidth: 420)
                }

                group("Startup") {
                    settingRow(
                        "Start RZMacro when I log in",
                        "It lives in the menu bar. Without it the macro keys do nothing and the lights fall back to what is stored on the devices."
                    ) {
                        Toggle("", isOn: Binding(get: { model.startsAtLogin }, set: { model.setStartsAtLogin($0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                    }
                    if let error = model.loginItemError {
                        Text(error).font(.system(size: 11.5)).foregroundStyle(Theme.danger)
                    }
                }

                HStack(spacing: 8) {
                    Button("Show Configuration File") { NSWorkspace.shared.activateFileViewerSelecting([Paths.configFile]) }
                        .buttonStyle(PillButtonStyle())
                    Button("Open Log") { NSWorkspace.shared.open(Paths.logFile) }
                        .buttonStyle(PillButtonStyle())
                    Spacer()
                    Text("RZMacro \(Daemon.version)").font(.system(size: 11.5)).foregroundStyle(Theme.tertiary)
                    Button("Quit RZMacro") { NSApp.terminate(nil) }
                        .buttonStyle(PillButtonStyle(kind: .danger))
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 18)
            .padding(.bottom, 28)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var separator: some View {
        Rectangle().fill(Theme.stroke).frame(height: 1)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title)
            VStack(alignment: .leading, spacing: 12) { content() }.panel()
        }
    }

    private func settingRow<Trailing: View>(_ title: String, _ detail: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            trailing()
        }
    }

    private func permission(_ name: String, _ purpose: String, granted: Bool, pane: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 18))
                .foregroundStyle(granted ? Theme.good : Theme.danger)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.system(size: 13, weight: .medium))
                Text(purpose).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
            Spacer()
            if granted {
                Text("Granted").font(.system(size: 11.5, weight: .medium)).foregroundStyle(Theme.good)
            } else {
                Button("Open System Settings") { openPrivacySettings(pane) }.buttonStyle(PillButtonStyle(kind: .primary, compact: true))
            }
        }
    }

    private func deviceRow(_ device: Daemon.DeviceSummary) -> some View {
        let broken = device.interfaces.filter { !$0.ok }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: device.kind == .keyboard ? "keyboard.fill" : "computermouse.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 34, height: 34)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.accent.opacity(0.16)))
                VStack(alignment: .leading, spacing: 3) {
                    Text(device.name).font(.system(size: 13, weight: .medium))
                    Text("USB 1532:\(String(format: "%04x", device.productID)) · firmware \(device.firmware ?? "unknown")")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.secondary)
                }
                Spacer()
                Text("Driver mode").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Toggle("", isOn: Binding(get: { model.config.driverMode[device.kind] ?? false }, set: { model.config.driverMode[device.kind] = $0 }))
                    .toggleStyle(.switch)
                    .labelsHidden()
            }
            Text(device.kind == .keyboard
                 ? "Needed for the macro keys. RZMacro then also handles the volume roller and Fn+F11/F12."
                 : "Makes every thumb button report, whatever is stored on the mouse.")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiary)
            ForEach(broken) { interface in
                Label("Interface \(interface.id) (\(interface.role)): \(interface.state)", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.danger)
            }
        }
    }
}
