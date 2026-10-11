import AppKit
import SwiftUI

/// The menu-bar item and the configuration window around the driver.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    private let daemon: Daemon
    private let model: AppModel
    private let showWindowAtLaunch: Bool
    private var statusItem: NSStatusItem?
    private var window: NSWindow?
    private let profileNote = ProfileNote()

    init(daemon: Daemon, showWindowAtLaunch: Bool) {
        self.daemon = daemon
        self.model = AppModel(daemon: daemon)
        self.showWindowAtLaunch = showWindowAtLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()
        daemon.onShowWindow = { [weak self] in self?.showWindow() }
        daemon.onProfileChanged = { [weak self] name, detail in self?.profileNote.show(name, detail) }
        daemon.onSnapshot = { [weak self] page, path, done in self?.snapshot(page: page, path: path, done: done) }

        // Opened by hand: show the window. Started at login: stay out of the way in the menu bar.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let atLogin = event?.eventID == kAEOpenApplication && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if showWindowAtLaunch && !atLogin { showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Logging out or shutting down is not a question; cmd-Q in the window is.
        let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: kAEQuitReason)
        guard reason == nil else { return .terminateNow }

        let alert = NSAlert()
        alert.messageText = "Quit RZMacro?"
        alert.informativeText = "The macro keys, thumb buttons and lighting only work while RZMacro is running. Closing the window keeps it running in the menu bar."
        alert.addButton(withTitle: "Close Window")
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            window?.close()
            return .terminateCancel
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        daemon.prepareForExit()
    }

    // MARK: Window

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "RZMacro"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        // The app is dark whatever the system is set to; controls and the title bar must follow.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.window)
        let titleBarHeight = window.frame.height - window.contentLayoutRect.height
        let host = NSHostingView(rootView: RootView(model: model, titleBarHeight: titleBarHeight))
        // The layout handles the title bar itself (see RootView), so no safe-area inset on top of that.
        host.safeAreaRegions = []
        window.contentView = host
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("RZMacroWindow")
        return window
    }

    func showWindow() {
        if window == nil { window = makeWindow() }
        // A Dock icon and menu bar while the window is open; back to menu-bar-only when it closes.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }

    /// Developer aid: renders one page of the window to a PNG (see `PageRenderer`).
    private func snapshot(page: String, path: String, done: @escaping (String) -> Void) {
        if window == nil { window = makeWindow() }
        let photosBefore = model.showsPhotos, profileBefore = model.editingProfile
        guard PageRenderer.apply(page, to: model) != nil else { return done("unknown page (\(Page.allCases.map(\.rawValue).joined(separator: ", ")))") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            defer {
                self?.model.preview(nil)
                self?.model.editingProfile = profileBefore
                self?.model.showsPhotos = photosBefore
            }
            guard let view = self?.window?.contentView, let data = PageRenderer.png(of: view) else { return done("could not draw the page") }
            do {
                try data.write(to: URL(fileURLWithPath: path))
                done("wrote \(path)")
            } catch {
                done("error: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Menus

    private func buildStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "RZMacro")
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// The menu-bar menu, put together each time it opens: the profiles, and which of them is
    /// in use, change behind its back.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusItem?.menu else { return }
        menu.removeAllItems()
        menu.addItem(withTitle: "Open RZMacro", action: #selector(openFromMenu), keyEquivalent: "").target = self
        let profiles = daemon.config.profiles
        if !profiles.isEmpty {
            menu.addItem(.separator())
            menu.addItem(.sectionHeader(title: "Profile"))
            for name in [nil] + profiles.filter({ !$0.partial }).map({ Optional($0.name) }) {
                let item = NSMenuItem(title: name ?? Profile.defaultName, action: #selector(useProfileFromMenu(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = name
                item.state = daemon.activeProfile == name ? .on : .off
                menu.addItem(item)
            }
            let partials = profiles.filter(\.partial)
            if !partials.isEmpty {
                // On top of that one: each is switched on and off by itself.
                menu.addItem(.separator())
                menu.addItem(.sectionHeader(title: "Partial Profiles"))
                for profile in partials {
                    let item = NSMenuItem(title: profile.name, action: #selector(useProfileFromMenu(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = profile.name
                    item.state = daemon.activePartials.contains { $0.name == profile.name } ? .on : .off
                    menu.addItem(item)
                }
            }
            menu.addItem(.separator())
            if daemon.isOverruled {
                // Chosen by hand over what the app or game in front asks for.
                let back = NSMenuItem(title: "Back to \(daemon.automaticProfile ?? Profile.defaultName) (Automatic)", action: #selector(resumeAutomaticFromMenu), keyEquivalent: "")
                back.target = self
                menu.addItem(back)
            }
            let automatic = NSMenuItem(title: "Switch Automatically", action: #selector(toggleAutomaticFromMenu), keyEquivalent: "")
            automatic.target = self
            automatic.state = daemon.config.autoSwitch ? .on : .off
            menu.addItem(automatic)
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit RZMacro", action: #selector(quitFromMenu), keyEquivalent: "").target = self
    }

    @objc private func openFromMenu() { showWindow() }

    @objc private func useProfileFromMenu(_ sender: NSMenuItem) { model.useProfile(sender.representedObject as? String) }

    @objc private func resumeAutomaticFromMenu() { model.resumeAutomaticProfile() }

    @objc private func toggleAutomaticFromMenu() { model.config.autoSwitch.toggle() }

    /// Asked for by name from the menu bar: no "are you sure".
    @objc private func quitFromMenu() { daemon.shutdown() }

    /// An accessory app gets no menu bar from a nib, and without an Edit menu the text fields
    /// have no copy, paste or undo.
    private func buildMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About RZMacro", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide RZMacro", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit RZMacro…", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "RZMacro", action: nil, keyEquivalent: "").submenu = appMenu

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu

        NSApp.mainMenu = main
    }
}

/// A note at the top of the screen, gone after a moment: which profile just came on, or which
/// partial one went on or off. It takes no clicks and no focus, and shows over a game in full
/// screen.
final class ProfileNote {
    private var panel: NSPanel?
    private var hiding: DispatchWorkItem?

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        return panel
    }

    func show(_ name: String, _ detail: String) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        let view = NSHostingView(rootView: ProfileNoteView(name: name, detail: detail))
        let size = view.fittingSize
        panel.contentView = view
        let area = screen.visibleFrame
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.maxY - size.height - 64, width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hiding?.cancel()
        let work = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                panel.animator().alphaValue = 0
            }, completionHandler: {
                // Shown again while fading: leave it up.
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            })
        }
        hiding = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}

private struct ProfileNoteView: View {
    let name: String
    let detail: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 17))
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.system(size: 17, weight: .bold)).foregroundStyle(Theme.text)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color(rgb: 0x14161C).opacity(0.95)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.white.opacity(0.16)))
        .fixedSize()
    }
}
