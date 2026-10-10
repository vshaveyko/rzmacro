import AppKit
import SwiftUI

/// The menu-bar item and the configuration window around the driver.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let daemon: Daemon
    private let model: AppModel
    private let showWindowAtLaunch: Bool
    private var statusItem: NSStatusItem?
    private var window: NSWindow?

    init(daemon: Daemon, showWindowAtLaunch: Bool) {
        self.daemon = daemon
        self.model = AppModel(daemon: daemon)
        self.showWindowAtLaunch = showWindowAtLaunch
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildStatusItem()
        daemon.onShowWindow = { [weak self] in self?.showWindow() }
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

    /// Developer aid: renders one page of the window to a PNG, without needing screen-recording
    /// permission. Options: `select=<button>` picks a button or `macro=<name>` a macro,
    /// `photos=on|off` chooses photo or drawing, and `config=<file>` shows that configuration
    /// instead of the real one (display only).
    private func snapshot(page: String, path: String, done: @escaping (String) -> Void) {
        let parts = page.split(separator: ",").map(String.init)
        guard let page = parts.first.flatMap(Page.init(rawValue:)) else { return done("unknown page (\(Page.allCases.map(\.rawValue).joined(separator: ", ")))") }
        if window == nil { window = makeWindow() }
        var photosBefore: Bool?
        for option in parts.dropFirst() {
            let pair = option.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            switch pair[0] {
            case "config": model.preview(try? Config.load(from: URL(fileURLWithPath: pair[1])))
            case "select": if let trigger = try? Trigger(parsing: pair[1]) { model.selectedButton[trigger.kind] = trigger }
            case "macro": model.selectedMacro = pair[1].replacingOccurrences(of: "_", with: " ")
            case "profile": model.appProfile = pair[1]
            case "photos": photosBefore = photosBefore ?? model.showsPhotos; model.showsPhotos = pair[1] == "on"
            default: break
            }
        }
        model.page = page
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            defer {
                self?.model.preview(nil)
                self?.model.appProfile = nil
                if let before = photosBefore { self?.model.showsPhotos = before }
            }
            guard let view = self?.window?.contentView else { return done("no view") }
            // Always at 2x, whatever screen the window happens to be on.
            let size = view.bounds.size
            guard let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
            else { return done("no bitmap") }
            bitmap.size = size
            view.cacheDisplay(in: view.bounds, to: bitmap)
            guard let data = bitmap.representation(using: .png, properties: [:]) else { return done("could not encode") }
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
        menu.addItem(withTitle: "Open RZMacro", action: #selector(openFromMenu), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit RZMacro", action: #selector(quitFromMenu), keyEquivalent: "").target = self
        item.menu = menu
        statusItem = item
    }

    @objc private func openFromMenu() { showWindow() }

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
