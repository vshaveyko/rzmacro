import AppKit
import SwiftUI

/// Developer aids for looking at the window without screen-recording permission: pages of it
/// drawn into PNG files. `rzmacro snapshot` asks the running driver for one; `rzmacro render`
/// draws one by itself — no driver, no devices, no permissions, nothing saved — so the window
/// can be looked at while the real driver is busy being used.
enum PageRenderer {
    /// `<page>[,option=value…]`: `select=<button>` picks a button, `macro=<name>` a macro and
    /// `profile=<name>` a profile (underscores for spaces), `photos=on|off` chooses photo or
    /// drawing, `config=<file>` shows that configuration instead of the real one (display
    /// only). For `render` alone, since it has no driver to ask: `active=<profile>` says which
    /// profile is in use, `hero=<name>` which Dota hero is being played, and `stuck=<key>+<key>`
    /// connects the page's device with those keys stuck down.
    /// Returns the page, or nil if there is no such page.
    static func apply(_ description: String, to model: AppModel) -> Page? {
        let parts = description.split(separator: ",").map(String.init)
        guard let page = parts.first.flatMap(Page.init(rawValue:)) else { return nil }
        for option in parts.dropFirst() {
            let pair = option.split(separator: "=", maxSplits: 1).map(String.init)
            guard pair.count == 2 else { continue }
            let name = pair[1].replacingOccurrences(of: "_", with: " ")
            switch pair[0] {
            case "config": model.preview(try? Config.load(from: URL(fileURLWithPath: pair[1])))
            case "select": if let trigger = try? Trigger(parsing: pair[1]) { model.selectedButton[trigger.kind] = trigger }
            case "macro": model.selectedMacro = name
            case "profile": model.editingProfile = name
            case "photos": model.showsPhotos = pair[1] == "on"
            case "active":
                model.activeProfile = name == Profile.defaultName ? nil : name
                model.profileReason = "chosen by hand"
            case "hero":
                model.dota = DotaWatcher.Status(found: true, installed: true, port: 35570, running: true, receiving: true, hero: pair[1])
                model.dotaLaunchOption = true
                if model.activeProfile != nil { model.profileReason = "playing \(DotaHeroes.title(pair[1]))" }
            case "stuck":
                guard let kind = DeviceKind(rawValue: page.rawValue), let known = DeviceProfile.known.first(where: { $0.kind == kind }),
                      let productID = known.productID else { break }
                model.devices = [Daemon.DeviceSummary(
                    id: "render", kind: kind, name: kind == .keyboard ? "Razer keyboard" : "Razer mouse", productID: productID, firmware: "1.0", inDriverMode: true,
                    stuckKeys: pair[1].split(separator: "+").map(String.init), interfaces: [])]
            default: break
            }
        }
        model.page = page
        return page
    }

    /// A view as a PNG, always at 2x, whatever screen it happens to be on.
    static func png(of view: NSView) -> Data? {
        let size = view.bounds.size
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return nil }
        bitmap.size = size
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap.representation(using: .png, properties: [:])
    }

    /// `rzmacro render <page>[,options] <path.png>`.
    static func run(_ description: String, path: String) -> Never {
        let app = NSApplication.shared
        // Never in front, never in the Dock: this must not take the screen from anything.
        app.setActivationPolicy(.prohibited)
        // A driver that is never started: it opens no devices and asks for no permissions.
        let model = AppModel(daemon: Daemon())
        model.savesChanges = false
        model.preview(Config.initial)
        model.inputMonitoring = true
        model.accessibility = true
        model.showsPhotos = false
        guard apply(description, to: model) != nil else {
            print("unknown page (\(Page.allCases.map(\.rawValue).joined(separator: ", ")))")
            exit(64)
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(Theme.window)
        let host = NSHostingView(rootView: RootView(model: model, titleBarHeight: window.frame.height - window.contentLayoutRect.height))
        host.safeAreaRegions = []
        window.contentView = host
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            do {
                guard let data = png(of: host) else { throw ConfigError("could not draw the page") }
                try data.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)")
                exit(0)
            } catch {
                print("error: \(error)")
                exit(1)
            }
        }
        app.run()
        exit(0)
    }
}
