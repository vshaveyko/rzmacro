import AppKit
import ApplicationServices
import IOKit.hid

final class Daemon {
    static let version = "0.3.0"

    /// Media controls the keyboard hands to software in driver mode; translated unless rebound.
    private static let builtinMedia: [UInt8: MediaKey] = [
        0x50: .volumeDown, 0x51: .volumeUp, 0x52: .mute, 0x53: .next, 0x54: .previous, 0x55: .play,
    ]

    private let devices = DeviceManager()
    private let engine = MacroEngine()
    private let server = ControlServer()
    private let tap = EventTap()
    private let lighting = LightingController()

    private(set) var config = Config()
    private(set) var configError: String?

    /// Hooks for the app's window. All called on the main thread.
    var onStateChanged: (() -> Void)?
    var onButton: ((Trigger, Bool) -> Void)?
    /// `rzmacro show` / a second launch of the app.
    var onShowWindow: (() -> Void)?
    /// Developer aid: render a page of the window to a PNG, then report how it went.
    var onSnapshot: ((_ page: String, _ path: String, _ done: @escaping (String) -> Void) -> Void)?
    private var configModified: Date?
    private var sniffers: [ControlConnection] = []
    /// Sniffers that asked for every raw report, ordinary typing included.
    private var verboseSniffers: [ControlConnection] = []
    private let started = Date()

    /// Assignment chosen when a button went down, so its release goes to the same one even if
    /// the frontmost app changed in between.
    private var active: [Trigger: Assignment] = [:]
    /// Key-downs we swallowed; the matching key-up must go too.
    private var swallowed = Set<CGKeyCode>()
    /// The same for mouse buttons, by button number.
    private var swallowedButtons = Set<Int>()
    private var modeOverride: [DeviceKind: DeviceMode] = [:]
    /// Lighting set from the command line, a macro or Fn+F11/F12; lasts until the config changes.
    private var lightOverride: LightSpec?
    private(set) var inputMonitoring = false
    private(set) var accessibility = false
    private var ticks = 0
    private var signalSources: [DispatchSourceSignal] = []

    /// Sets everything up; the caller then runs the main run loop.
    func start() {
        try? FileManager.default.createDirectory(at: Paths.configDir, withIntermediateDirectories: true)
        Log.shared.open()
        log("rzmacro \(Self.version) starting (pid \(getpid()))")

        installSignalHandlers()
        server.onCommand = { [unowned self] line, connection in self.command(line, connection) }
        do { try server.start() } catch { log("control socket: \(error)") }

        if !FileManager.default.fileExists(atPath: Paths.configFile.path) {
            try? Config.initial.save(to: Paths.configFile)
            log("wrote default config to \(Paths.configFile.path)")
        }
        reloadConfig()

        inputMonitoring = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if !inputMonitoring {
            log("Input Monitoring permission missing — grant it in System Settings > Privacy & Security > Input Monitoring")
            // IOHIDRequestAccess is answered "denied" without a prompt or a list entry on current
            // macOS; the CoreGraphics request is the one that registers the app in the pane.
            CGRequestListenEventAccess()
        }
        accessibility = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        if !accessibility {
            log("Accessibility permission missing — grant it in System Settings > Privacy & Security > Accessibility")
        }

        devices.onEvent = { [unowned self] device, source, pressed in self.handle(device, source, pressed) }
        devices.onReport = { [unowned self] device, interface, bytes in self.sniff(device, interface, bytes) }
        devices.onDevicesChanged = { [unowned self] in self.devicesChanged() }
        devices.start()

        engine.onLight = { [unowned self] command in _ = self.applyLight(command) }
        tap.handler = { [unowned self] type, event in self.shouldSwallow(type, event) }
        updateTap()

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [unowned self] _ in self.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [unowned self] _ in
            // USB devices come back in normal mode after sleep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.applyModes()
                self.lighting.invalidate()
            }
        }
    }

    // MARK: Lifecycle

    private func installSignalHandlers() {
        for number in [SIGINT, SIGTERM, SIGHUP] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [unowned self] in
                log("signal \(number), shutting down")
                self.shutdown()
            }
            source.resume()
            signalSources.append(source)
        }
    }

    /// Hands the devices back to their firmware before going away.
    func releaseDevices() {
        tap.stop()
        for device in devices.devices {
            guard let control = device.control, (try? control.deviceMode()) == DeviceMode.driver.rawValue else { continue }
            try? control.setDeviceMode(.normal)
        }
    }

    /// Everything that has to happen before the process goes away, however it goes away.
    func prepareForExit() {
        releaseDevices()
        server.stop()
        log("stopped")
    }

    func shutdown() -> Never {
        prepareForExit()
        exit(0)
    }

    /// Starts over in a fresh process (a new permission only takes effect in one).
    private func restart() -> Never {
        prepareForExit()
        let bundle = Bundle.main.bundleURL
        if bundle.pathExtension == "app" {
            // As an app: have LaunchServices start a clean instance rather than exec in place,
            // which would leave the window server holding state from the old image.
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-n", bundle.path, "--args"] + CommandLine.arguments.dropFirst()
            try? open.run()
            open.waitUntilExit()
            exit(0)
        }
        execv(Bundle.main.executablePath ?? CommandLine.arguments[0], CommandLine.unsafeArgv)
        log("re-exec failed: \(String(cString: strerror(errno)))")
        exit(1)
    }

    private func tick() {
        ticks += 1
        let listen = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if listen && !inputMonitoring {
            log("Input Monitoring granted, restarting to open the devices")
            restart()
        }
        let trusted = AXIsProcessTrusted()
        if trusted != accessibility {
            accessibility = trusted
            log("Accessibility permission \(trusted ? "granted" : "revoked")")
            updateTap()
            onStateChanged?()
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: Paths.configFile.path))?[.modificationDate] as? Date
        if modified != configModified { reloadConfig() }
        if ticks % 15 == 0 { applyModes() }
        lighting.refresh()
        sniffers.removeAll { $0.isClosed }
        verboseSniffers.removeAll { $0.isClosed }
    }

    private func reloadConfig() {
        configModified = (try? FileManager.default.attributesOfItem(atPath: Paths.configFile.path))?[.modificationDate] as? Date
        let previous = config
        do {
            config = try Config.load(from: Paths.configFile)
            configError = nil
            log("config loaded: \(config.bindings.count) bindings, \(config.apps.count) app profiles")
        } catch {
            configError = "\(error)"
            log("config error: \(error) — keeping the previous configuration")
        }
        applyConfig(previous: previous)
    }

    /// Puts `config` into effect. `previous` is what was in effect before: only what differs
    /// is touched, so editing a binding doesn't poke the devices.
    private func applyConfig(previous: Config) {
        engine.setLibrary(config.macros, keyDelay: config.keyDelay)
        if previous.lighting != config.lighting {
            lightOverride = nil
            lighting.update(spec: config.lighting)
        }
        if previous.driverMode != config.driverMode { applyModes() }
        updateTap()
        onStateChanged?()
    }

    /// The app edited the configuration: put it into effect and write it to the file.
    func updateConfig(_ new: Config) {
        guard new != config else { return }
        let previous = config
        config = new
        configError = nil
        persistConfig()
        applyConfig(previous: previous)
    }

    /// Shows a lighting change on the devices right away, ahead of `updateConfig`.
    func previewLighting(_ spec: LightSpec?) {
        lightOverride = nil
        lighting.update(spec: spec)
    }

    private func persistConfig() {
        do {
            try config.save(to: Paths.configFile)
            // Our own write must not look like an outside edit to the file watcher.
            configModified = (try? FileManager.default.attributesOfItem(atPath: Paths.configFile.path))?[.modificationDate] as? Date
        } catch {
            log("could not save the config: \(error)")
        }
    }

    private func devicesChanged() {
        for device in devices.devices {
            let interfaces = device.interfaces.map { "if\($0.number) \($0.role) \(Self.describe($0))" }.joined(separator: "; ")
            log("device: \(device.kind.rawValue) \(device.name) (\(String(format: "%04x", device.productID))) — \(interfaces)")
        }
        swallowed.removeAll()
        swallowedButtons.removeAll()
        applyModes()
        updateTap()
        lighting.update(targets: devices.devices.compactMap { device in
            guard let control = device.control else { return nil }
            let layout = DeviceProfile.profile(productID: device.productID, kind: device.kind).lights
            return LightingController.Target(name: device.name, control: control, layout: layout)
        })
        onStateChanged?()
    }

    private func wantedMode(_ kind: DeviceKind) -> DeviceMode {
        modeOverride[kind] ?? ((config.driverMode[kind] ?? false) ? .driver : .normal)
    }

    private func applyModes() {
        var changed = false
        for device in devices.devices {
            guard let control = device.control else { continue }
            let wanted = wantedMode(device.kind)
            do {
                if device.firmware == nil { device.firmware = try control.firmwareVersion() }
                let current = try control.deviceMode()
                if current != wanted.rawValue {
                    try control.setDeviceMode(wanted)
                    device.rawDown.removeAll()
                    changed = true
                    log("\(device.name): device mode \(String(format: "%02x", current)) -> \(wanted)")
                }
                device.lastModeError = nil
            } catch {
                let message = "\(error)"
                if device.lastModeError != message { log("\(device.name): \(message)") }
                device.lastModeError = message
            }
        }
        // A device that had to be put back into its mode was reset; its LEDs were too.
        if changed { lighting.invalidate() }
    }

    // MARK: Button events

    private func lookup(_ trigger: Trigger) -> Assignment? {
        if let bundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
           let binding = config.apps[bundleID]?[trigger] {
            return binding
        }
        return config.bindings[trigger]
    }

    private func handle(_ device: RazerDevice, _ source: KeySource, _ pressed: Bool) {
        let trigger = Trigger(kind: device.kind, source: source)
        onButton?(trigger, pressed)
        if !sniffers.isEmpty {
            let name = trigger.displayName == trigger.description ? "" : "  (\(trigger.displayName))"
            broadcast("event   \(trigger) \(pressed ? "down" : "up")\(name)")
        }
        if pressed {
            if let binding = lookup(trigger) {
                active[trigger] = binding
                engine.press(id: trigger.description, assignment: binding)
            } else if device.kind == .keyboard, case .raw(let code) = source, let key = Self.builtinMedia[code] {
                engine.media(key)
            }
        } else if let binding = active.removeValue(forKey: trigger) {
            engine.release(id: trigger.description, assignment: binding)
        }
    }

    // MARK: Lighting

    /// Returns a line describing what happened, for the command-line client.
    private func applyLight(_ command: LightCommand) -> String {
        var spec = lightOverride ?? config.lighting
        switch command {
        case .set(let new):
            spec = new
        case .brightness(let value):
            spec?.brightness = value
        case .adjust(let delta):
            if let current = spec?.brightness { spec?.brightness = min(max(current + delta, 0), 1) }
        }
        guard let spec else {
            // Nothing of ours to dim: fall back to what the firmware's own Fn keys would do.
            if case .adjust(let delta) = command { return adjustKeyboardBacklight(delta) }
            return "lighting is not managed — choose an effect first (e.g. `rzmacro light spectrum`)"
        }
        if case .set = command {
            lightOverride = spec
        } else if lightOverride != nil {
            lightOverride = spec
        } else {
            // Brightness is a setting, not a passing effect: keep it.
            config.lighting = spec
            persistConfig()
            onStateChanged?()
        }
        lighting.update(spec: spec)
        return "lighting: \(spec)"
    }

    private func adjustKeyboardBacklight(_ delta: Double) -> String {
        for device in devices.devices where device.kind == .keyboard {
            guard let control = device.control, let zone = DeviceProfile.profile(productID: device.productID, kind: .keyboard).lights.zones.first else { continue }
            do {
                let level = min(max(Int(try control.brightness(led: zone)) + Int(delta * 255), 0), 255)
                try control.setBrightness(UInt8(level), led: zone)
                return "\(device.name): backlight \(level * 100 / 255)%"
            } catch {
                return "\(device.name): \(error)"
            }
        }
        return "no keyboard"
    }

    // MARK: Event tap: mouse-typed keystrokes and the keyboard's Fn layer

    private static let f9: CGKeyCode = 101, f10: CGKeyCode = 109, f11: CGKeyCode = 103, f12: CGKeyCode = 111

    /// In driver mode the keyboard stops handling Fn combinations and sends the plain F-key.
    private var fnLayerActive: Bool {
        devices.devices.contains { $0.kind == .keyboard && wantedMode(.keyboard) == .driver }
    }

    private var fnHeld: Bool {
        devices.devices.contains { $0.kind == .keyboard && $0.rawDown.contains(0x01) }
    }

    /// The kinds of event that have to be looked at, given what is bound.
    private var tappedEvents: [CGEventType] {
        let bound = ([config.bindings] + Array(config.apps.values)).flatMap(\.keys).filter { $0.kind == .mouse }.map(\.source)
        var events: [CGEventType] = []
        if fnLayerActive || bound.contains(where: { if case .key = $0 { return true } else { return false } }) {
            events += [.keyDown, .keyUp]
        }
        if bound.contains(where: { if case .button = $0 { return true } else { return false } }) {
            events += [.rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp]
        }
        if bound.contains(where: { if case .wheel = $0 { return true } else { return false } }) {
            events.append(.scrollWheel)
        }
        return events
    }

    private func updateTap() {
        let events = tappedEvents
        if !events.isEmpty && accessibility {
            if !tap.start(events: events) { log("could not create the event tap (Accessibility permission?)") }
        } else {
            tap.stop()
        }
    }

    private func shouldSwallow(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .keyDown, .keyUp: return shouldSwallowKey(type, event)
        case .rightMouseDown, .otherMouseDown:
            // Only a click that a Razer mouse is making, and only if that button is reassigned;
            // the assignment itself is run from the device's own report.
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard lookup(Trigger(kind: .mouse, source: .button(button))) != nil,
                  devices.devices.contains(where: { $0.kind == .mouse && $0.isButtonDownNow(button) }) else { return false }
            swallowedButtons.insert(button)
            return true
        case .rightMouseUp, .otherMouseUp:
            return swallowedButtons.remove(Int(event.getIntegerValueField(.mouseEventButtonNumber))) != nil
        case .scrollWheel: return wheelTurned(event)
        default: return false
        }
    }

    /// A turn of a mouse wheel. There is no "held" state to ask the device about, so this is
    /// recognised by what it is — stepped, not the continuous scrolling of a trackpad — and
    /// the assignment is run from here.
    private func wheelTurned(_ event: CGEvent) -> Bool {
        guard event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0,
              devices.devices.contains(where: { $0.kind == .mouse }) else { return false }
        let delta = event.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        guard delta != 0 else { return false }
        // Which way the wheel itself turned, whatever "natural scrolling" did to the sign.
        let inverted = NSEvent(cgEvent: event)?.isDirectionInvertedFromDevice ?? false
        let trigger = Trigger(kind: .mouse, source: .wheel(up: (delta > 0) != inverted))
        guard let assignment = lookup(trigger) else { return false }
        if !sniffers.isEmpty { broadcast("event   \(trigger) (\(trigger.displayName))") }
        onButton?(trigger, true)
        engine.press(id: trigger.description, assignment: assignment)
        engine.release(id: trigger.description, assignment: assignment)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in self?.onButton?(trigger, false) }
        return true
    }

    private func shouldSwallowKey(_ type: CGEventType, _ event: CGEvent) -> Bool {
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp { return swallowed.remove(code) != nil }
        guard type == .keyDown else { return false }

        if fnHeld {
            switch code {
            case Self.f11, Self.f12:
                // Backlight down / up, as printed on the keys.
                _ = applyLight(.adjust(code == Self.f12 ? 0.1 : -0.1))
                swallowed.insert(code)
                return true
            case Self.f9, Self.f10:
                // On-the-fly macro recording and gaming mode: firmware features with no meaning here.
                swallowed.insert(code)
                return true
            default:
                break
            }
        }
        guard let usage = Keys.usageByCode[code] else { return false }

        let heldByMouse = devices.devices.contains { $0.kind == .mouse && $0.isKeyDownNow(usage) }
        if heldByMouse && (swallowed.contains(code) || lookup(Trigger(kind: .mouse, source: .key(usage))) != nil) {
            if !sniffers.isEmpty && !swallowed.contains(code) { broadcast(String(format: "tap     swallowed key:%02x typed by the mouse", usage)) }
            swallowed.insert(code)
            return true
        }
        swallowed.remove(code)
        return false
    }

    // MARK: Sniffing

    private func broadcast(_ line: String, verboseOnly: Bool = false) {
        let stamp = String(format: "%9.3f ", Date().timeIntervalSince(started))
        if verboseOnly {
            verboseSniffers.removeAll { !$0.send(stamp + line) }
        } else {
            sniffers.removeAll { !$0.send(stamp + line) }
        }
    }

    /// Raw reports are only ever streamed to an attached `rzmacro sniff`, never written to the
    /// log — and what you type on the keyboard only to `rzmacro sniff all`.
    private func sniff(_ device: RazerDevice, _ interface: HIDInterface, _ bytes: [UInt8]) {
        guard !sniffers.isEmpty else { return }
        let isTyping = device.kind == .keyboard && interface.isKeyboard && (interface.maxInput <= 8 || bytes[0] == 1)
        var shown = bytes
        if interface.isMouse && device.kind == .mouse {
            // Only the button byte; movement and wheel would drown everything else.
            shown = Array(bytes.prefix(1))
            if shown == interface.lastSniffed { return }
            interface.lastSniffed = shown
        }
        broadcast("report  \(device.kind.rawValue) if\(interface.number) [\(interface.role)]: \(hex(shown))", verboseOnly: isTyping)
    }

    // MARK: State for the app

    struct DeviceSummary: Identifiable {
        struct Interface: Identifiable {
            let id: Int
            let role: String
            let state: String
            let ok: Bool
        }

        let id: String
        let kind: DeviceKind
        let name: String
        let productID: Int
        let firmware: String?
        let inDriverMode: Bool
        let interfaces: [Interface]
    }

    var deviceSummaries: [DeviceSummary] {
        devices.devices.map { device in
            DeviceSummary(
                id: "\(device.productID)-\(device.locationID)", kind: device.kind, name: device.name,
                productID: device.productID, firmware: device.firmware,
                inDriverMode: wantedMode(device.kind) == .driver && device.lastModeError == nil && device.control != nil,
                interfaces: device.interfaces.map {
                    .init(id: $0.number, role: $0.role, state: Self.describe($0), ok: $0.openResult == kIOReturnSuccess)
                })
        }
    }

    var isTapRunning: Bool { tap.isRunning }
    var lightingStatus: String { lighting.status }

    /// Runs a macro once, for the app's "Test" button.
    func play(_ macro: Macro) { engine.play(macro) }

    // MARK: Control commands

    private static func describe(_ interface: HIDInterface) -> String {
        let result = interface.openResult
        switch result {
        case kIOReturnSuccess: return interface.isSeized ? "open (exclusive)" : "open"
        case kIOReturnNotPermitted: return "NOT PERMITTED (Input Monitoring)"
        case kIOReturnExclusiveAccess: return "busy (exclusive access)"
        default: return String(format: "error 0x%08x", UInt32(bitPattern: result))
        }
    }

    private func statusText() -> String {
        var lines = ["rzmacro \(Self.version)  pid \(getpid())"]
        lines.append("permissions: input-monitoring=\(inputMonitoring ? "granted" : "MISSING")  accessibility=\(accessibility ? "granted" : "MISSING")  event-tap=\(tap.isRunning ? "on" : "off")")
        lines.append("config: \(Paths.configFile.path)")
        if let configError { lines.append("  CONFIG ERROR: \(configError)") }
        lines.append("  \(config.bindings.count) bindings, \(config.apps.count) app profiles")
        for trigger in config.bindings.keys.map(\.displayName).sorted() { lines.append("    \(trigger)") }
        lines.append("lighting: \(lighting.status)")
        lines.append("devices:")
        if devices.devices.isEmpty { lines.append("  (none)") }
        for device in devices.devices {
            var mode = "mode unknown"
            if let control = device.control {
                do {
                    let current = try control.deviceMode()
                    mode = "mode \(DeviceMode(rawValue: current).map { "\($0)" } ?? String(format: "0x%02x", current)) (wanted \(wantedMode(device.kind)))"
                } catch { mode = "mode unreadable: \(error)" }
            } else {
                mode = "no control channel"
            }
            lines.append("  \(device.kind.rawValue): \(device.name) (1532:\(String(format: "%04x", device.productID)))  fw \(device.firmware ?? "?")  \(mode)")
            for interface in device.interfaces {
                lines.append("      if\(interface.number) \(interface.role): \(Self.describe(interface))")
            }
        }
        return lines.joined(separator: "\n")
    }

    private func command(_ line: String, _ connection: ControlConnection) {
        let parts = line.split(separator: " ").map(String.init)
        func reply(_ text: String) {
            connection.send(text)
            connection.close()
        }
        func targets(_ name: String?) -> [RazerDevice]? {
            guard let name else { return nil }
            if name == "all" { return devices.devices }
            guard let kind = DeviceKind(configName: name) else { return nil }
            return devices.devices.filter { $0.kind == kind }
        }

        switch parts.first ?? "" {
        case "status":
            reply(statusText())
        case "reload":
            reloadConfig()
            reply(configError.map { "config error: \($0)" } ?? "config reloaded: \(config.bindings.count) bindings, \(config.apps.count) app profiles")
        case "quit":
            reply("stopping")
            shutdown()
        case "press":
            // press <button> [ms] — as if the button were pressed and held that long
            guard let trigger = parts[safe: 1].flatMap({ try? Trigger(parsing: $0) }) else {
                return reply("usage: press <keyboard.M1|mouse.7|…> [milliseconds held]")
            }
            guard let assignment = lookup(trigger) else { return reply("\(trigger.displayName) has nothing assigned") }
            let held = max(parts[safe: 2].flatMap(Int.init) ?? 50, 0)
            engine.press(id: trigger.description, assignment: assignment)
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(held)) { [engine] in
                engine.release(id: trigger.description, assignment: assignment)
            }
            reply("pressed \(trigger.displayName) for \(held) ms")
        case "show":
            onShowWindow?()
            reply("ok")
        case "snapshot":
            // snapshot <page> <png path>
            guard let page = parts[safe: 1], let path = parts[safe: 2] else { return reply("usage: snapshot <page> <path.png>") }
            guard let onSnapshot else { return reply("no window") }
            onSnapshot(page, path) { reply($0) }
        case "sniff":
            // sniff [seconds] [all]
            let verbose = parts.contains("all")
            connection.send("sniffing — press buttons on the Razer devices" + (verbose ? " (including everything typed on the keyboard)" : ""))
            sniffers.append(connection)
            if verbose { verboseSniffers.append(connection) }
            if let seconds = parts.dropFirst().compactMap(Double.init).first {
                DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                    connection.send("sniff finished")
                    connection.close()
                }
            }
        case "light":
            // light <effect> [colours] [options] | light brightness <N|+N|-N>
            if parts.count == 1 { return reply("lighting: \(lighting.status)") }
            do { reply(applyLight(try LightCommand(words: Array(parts.dropFirst())))) } catch { reply("error: \(error)") }
        case "mode":
            // mode <keyboard|mouse|all> <normal|driver|auto> — temporary, until restart
            guard let selected = targets(parts[safe: 1]), let wanted = parts[safe: 2] else {
                return reply("usage: mode <keyboard|mouse|all> <normal|driver|auto>")
            }
            for kind in Set(selected.map(\.kind)) {
                switch wanted {
                case "normal": modeOverride[kind] = .normal
                case "driver": modeOverride[kind] = .driver
                case "auto": modeOverride[kind] = nil
                default: return reply("usage: mode <keyboard|mouse|all> <normal|driver|auto>")
                }
            }
            applyModes()
            reply(statusText())
        case "raw":
            // raw <keyboard|mouse> <class> <id> <size> [args…] — all hex; prints the device's answer
            let bytes = parts.dropFirst(2).map { UInt8($0, radix: 16) }
            guard let device = targets(parts[safe: 1])?.first, bytes.count >= 3, !bytes.contains(nil) else {
                return reply("usage: raw <keyboard|mouse> <class> <id> <size> [args…]  (hex bytes)")
            }
            guard let control = device.control else { return reply("\(device.name): control interface is not open") }
            let request = bytes.compactMap { $0 }
            do {
                let response = try control.send(class: request[0], id: request[1], size: request[2], args: Array(request.dropFirst(3)))
                reply("ok size=\(String(format: "%02x", response[5])) args: \(hex(response[8..<(8 + min(Int(response[5]), 80))]))")
            } catch {
                reply("error: \(error)")
            }
        default:
            reply("unknown command \"\(line)\"")
        }
    }
}
