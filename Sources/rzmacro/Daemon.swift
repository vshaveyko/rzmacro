import AppKit
import ApplicationServices
import IOKit.hid

extension Config {
    /// The profiles, partial or whole, that the rules ask for, and which rule, given the app in
    /// front, the apps that are running, and what Dota 2 says: the hero being played, and
    /// whether a match is on. A profile's rule is one of its apps being in front, or running if
    /// it says so; for Dota it may ask for a match or the menus, and for certain heroes, too.
    /// The most specific comes first — a hero, then a match or the menus, then an app in front,
    /// then one merely running — and under the same kind of rule, the earlier in the list.
    func matches(partial: Bool, front: String?, hero: String?, activity: DotaActivity?, running: () -> Set<String>) -> [Daemon.ActivePartial] {
        guard autoSwitch else { return [] }
        var runningApps: Set<String>?
        func isRunning(_ app: String) -> Bool {
            if runningApps == nil { runningApps = running() }
            return runningApps?.contains(app) == true
        }
        var matches: [Daemon.ActivePartial] = []
        for profile in profiles where profile.partial == partial {
            var best: Daemon.ProfileReason?
            for app in profile.apps {
                guard app == front || (profile.whileRunning && isRunning(app)) else { continue }
                var reason = app == front ? Daemon.ProfileReason.appInFront(app) : .appRunning(app)
                if app == DotaWatcher.bundleID {
                    if let wanted = profile.dota {
                        guard activity == wanted else { continue }
                        reason = .dota(wanted)
                    }
                    if !profile.heroes.isEmpty {
                        guard let hero, profile.heroes.contains(hero) else { continue }
                        reason = .hero(hero)
                    }
                }
                if best.map({ reason.rank < $0.rank }) ?? true { best = reason }
            }
            if let best { matches.append(Daemon.ActivePartial(name: profile.name, reason: best)) }
        }
        return matches.enumerated()
            .sorted { ($0.element.reason.rank, $0.offset) < ($1.element.reason.rank, $1.offset) }
            .map(\.element)
    }
}

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
    private let remapper = KeyRemapper()
    private let dota = DotaWatcher()

    private(set) var config = Config()
    private(set) var configError: String?

    /// Hooks for the app's window. All called on the main thread.
    var onStateChanged: (() -> Void)?
    var onButton: ((Trigger, Bool) -> Void)?
    /// `rzmacro show` / a second launch of the app.
    var onShowWindow: (() -> Void)?
    /// The profile in force changed, or a partial one went on or off: its name, and what
    /// happened and why, for a note on screen.
    var onProfileChanged: ((_ name: String, _ detail: String) -> Void)?
    /// While set, the next ordinary key pressed on the keyboard goes here instead of doing
    /// anything (the window's "pick a key by pressing it").
    var onKeyPick: ((Trigger) -> Void)?
    /// The window is recording key presses. Until it stops the keyboard's keys are themselves
    /// again, so that what is recorded is the key pressed, not what a profile makes of it.
    var isRecordingKeys = false {
        didSet { if isRecordingKeys != oldValue { applyKeyRemap() } }
    }
    /// Developer aid: render a page of the window to a PNG, then report how it went.
    var onSnapshot: ((_ page: String, _ path: String, _ done: @escaping (String) -> Void) -> Void)?
    private var configModified: Date?
    private var sniffers: [ControlConnection] = []
    /// Sniffers that asked for every raw report, ordinary typing included.
    private var verboseSniffers: [ControlConnection] = []
    private let started = Date()

    /// Assignment chosen when a button went down, so its release goes to the same one even if
    /// the profile changed in between.
    private var active: [Trigger: Assignment] = [:]
    /// Ordinary keys the window has been told are down.
    private var shownDown = Set<Trigger>()

    /// Why a profile is the one in force.
    enum ProfileReason: Equatable {
        case chosen
        case appInFront(String), appRunning(String), hero(String), dota(DotaActivity)

        var text: String {
            switch self {
            case .chosen: return "chosen by hand"
            case .appInFront(let bundleID): return "\(appDisplayName(bundleID)) is in front"
            case .appRunning(let bundleID): return "\(appDisplayName(bundleID)) is running"
            case .hero(let name): return "playing \(DotaHeroes.title(name))"
            case .dota(.playing): return "in a Dota 2 match"
            case .dota(.menu): return "in Dota 2's menus"
            }
        }

        /// How specific the rule is: the lower, the more.
        var rank: Int {
            switch self {
            case .hero: return 0
            case .dota: return 1
            case .appInFront: return 2
            case .appRunning: return 3
            case .chosen: return 4
            }
        }

        /// Something the game did, rather than a window coming to the front.
        var isGameNews: Bool {
            switch self {
            case .hero, .dota: return true
            default: return false
            }
        }
    }

    /// The profile in force; nil is the default bindings.
    private(set) var activeProfile: String?
    private(set) var profileReason = ProfileReason.chosen
    /// What the rules ask for right now, whether or not they are being overruled by hand.
    private(set) var automaticProfile: String?
    /// A profile was chosen by hand while a rule was in force. That lasts until the rules ask
    /// for something else — leaving the game, another hero.
    private(set) var isOverruled = false
    private var overrulingProfile: String?
    /// The profile chosen by hand, in force whenever no rule applies. It is where things were
    /// left, not a setting, so it is kept out of the config file.
    private var chosenProfile: String? {
        get { UserDefaults.standard.string(forKey: "profile") }
        set { UserDefaults.standard.set(newValue, forKey: "profile") }
    }
    /// A partial profile that is on, and why.
    struct ActivePartial: Equatable {
        let name: String
        let reason: ProfileReason

        var text: String { reason == .chosen ? "switched on by hand" : reason.text }
    }

    /// The partial profiles that are on, on top of the profile in force. The one that wins a
    /// button several of them change comes first.
    private(set) var activePartials: [ActivePartial] = []
    /// Partial profiles switched on by hand, which stay on until switched off. Like
    /// `chosenProfile`, where things were left.
    private var partialsByHand: [String] {
        get { UserDefaults.standard.stringArray(forKey: "partials") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "partials") }
    }
    /// Partial profiles switched off by hand while a rule asks for them. That lasts until the
    /// rule stops asking.
    private var partialsOverruled = Set<String>()
    /// Every assignment in force: the active profile's, and on top the partial profiles'.
    private var layer: [Trigger: Assignment] = [:]
    private var lastDotaStatus = DotaWatcher.Status()
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
        devices.onStuckKeys = { [unowned self] device in
            log("\(device.name): \(Self.stuckText(device) ?? "no longer reports keys held by nothing")")
            self.onStateChanged?()
        }
        devices.start()

        engine.onLight = { [unowned self] command in _ = self.applyLight(command) }
        engine.onProfile = { [unowned self] name in _ = self.switchProfile(name) }
        engine.onSend = { [unowned self] moment, what in
            DispatchQueue.main.async { if !self.sniffers.isEmpty { self.broadcast("sent    \(what)", at: moment) } }
        }

        dota.onChange = { [unowned self] in self.refreshProfile() }
        dota.start()
        // What is in front, and what is running, decide the profile.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [unowned self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.bundleIdentifier == DotaWatcher.bundleID {
                    // The game may have been installed, or its library drive plugged in, since we started.
                    if name == NSWorkspace.didLaunchApplicationNotification { self.dota.start() }
                    if name == NSWorkspace.didTerminateApplicationNotification { self.dota.gameQuit() }
                }
                self.refreshProfile()
            }
        }
        tap.handler = { [unowned self] type, event in self.shouldSwallow(type, event) }
        // Again, now that the permissions and the game's state are known.
        refreshProfile()

        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [unowned self] _ in self.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [unowned self] _ in
            // USB devices come back in normal mode after sleep.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                self.applyModes()
                self.remapper.devicesChanged()
                self.applyKeyRemap()
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
        // Not with a button down (see applyModes). Buttons are heard coming up by the run loop.
        let deadline = Date().addingTimeInterval(Self.modeWait)
        while Date() < deadline, devices.devices.contains(where: { $0.control != nil && $0.hasButtonsDown }) {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        tap.stop()
        remapper.clear(keyboards: keyboardIDs)
        for device in devices.devices {
            guard let control = device.control, (try? control.deviceMode()) == DeviceMode.driver.rawValue else { continue }
            try? control.setDeviceMode(.normal)
        }
    }

    /// Everything that has to happen before the process goes away, however it goes away.
    func prepareForExit() {
        releaseDevices()
        dota.stop()
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
            applyKeyRemap()
            updateTap()
            onStateChanged?()
        }
        let modified = (try? FileManager.default.attributesOfItem(atPath: Paths.configFile.path))?[.modificationDate] as? Date
        if modified != configModified { reloadConfig() }
        if ticks % 15 == 0 {
            applyModes()
            // A keyboard that reconnected behind our back has lost its key mapping; this only
            // touches one that has.
            remapper.devicesChanged()
            applyKeyRemap()
        }
        if dota.hero != nil && !DotaWatcher.isRunning { dota.gameQuit() }
        let dotaStatus = dota.status
        if dotaStatus != lastDotaStatus {
            // A match that has gone quiet is over, which nothing but the clock says.
            if dotaStatus.activity != lastDotaStatus.activity {
                log("dota: \(dotaStatus.activity.map { ProfileReason.dota($0).text } ?? "what the game is doing can't be told")")
            }
            lastDotaStatus = dotaStatus
            refreshProfile()
        }
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
            log("config loaded: \(config.bindings.count) bindings, \(config.profiles.count) profiles")
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
        devices.wanted = Set(config.keyboards.map(\.id))
        refreshProfile()
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
            log("device: \(device.kind.rawValue) \(device.name) (\(device.id)) — \(interfaces)")
        }
        swallowed.removeAll()
        swallowedButtons.removeAll()
        applyModes()
        remapper.devicesChanged()
        applyKeyRemap()
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

    /// How long a change of device mode waits for the device's buttons to come up.
    private static let modeWait: TimeInterval = 2
    private var modeRetryPending = false

    private func applyModes() {
        var changed = false, waiting = false
        for device in devices.devices {
            guard let control = device.control else { continue }
            let wanted = wantedMode(device.kind)
            do {
                if device.firmware == nil { device.firmware = try control.firmwareVersion() }
                let current = try control.deviceMode()
                if current != wanted.rawValue {
                    // Not with a button down: the device would go on reporting it down long
                    // after it came up (see KeySlots). A press is short, so wait for a gap —
                    // but not for ever, for a button that is stuck already.
                    if device.hasButtonsDown {
                        let since = device.modeWaitSince ?? Date()
                        device.modeWaitSince = since
                        if Date().timeIntervalSince(since) < Self.modeWait {
                            waiting = true
                            continue
                        }
                        log("\(device.name): a button has stayed down; changing device mode regardless")
                    }
                    try control.setDeviceMode(wanted)
                    device.rawDown.removeAll()
                    changed = true
                    log("\(device.name): device mode \(String(format: "%02x", current)) -> \(wanted)")
                }
                device.modeWaitSince = nil
                device.lastModeError = nil
            } catch {
                let message = "\(error)"
                if device.lastModeError != message { log("\(device.name): \(message)") }
                device.lastModeError = message
            }
        }
        // A device that had to be put back into its mode was reset; its LEDs were too.
        if changed { lighting.invalidate() }
        if waiting && !modeRetryPending {
            modeRetryPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.modeRetryPending = false
                self?.applyModes()
            }
        }
    }

    /// What to say about a device that reports keys down with nothing holding them.
    private static func stuckText(_ device: RazerDevice) -> String? {
        let names = stuckKeyNames(device)
        guard !names.isEmpty else { return nil }
        return "reports \(names.joined(separator: ", ")) held down with no button holding \(names.count == 1 ? "it" : "them") — unplug the device itself and plug it back in"
    }

    private static func stuckKeyNames(_ device: RazerDevice) -> [String] {
        device.stuckKeys.sorted().map { KeyboardKeys.byUsage[$0]?.title ?? String(format: "key %02x", $0) }
    }

    // MARK: Profiles

    /// The profiles, partial or whole, that the rules ask for right now, and which rule.
    private func automaticMatches(partial: Bool) -> [ActivePartial] {
        config.matches(
            partial: partial, front: NSWorkspace.shared.frontmostApplication?.bundleIdentifier, hero: dota.hero, activity: dota.activity,
            running: { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) })
    }

    /// Works out which profile is in force, and which partial ones are on top of it, and puts
    /// their assignments into effect. Called whenever anything it depends on may have changed;
    /// `byHand` when that was the user switching profile.
    private func refreshProfile(byHand: Bool = false) {
        // Of the whole profiles the rules ask for, the first is the one.
        let match = automaticMatches(partial: false).first
        if match?.name != automaticProfile { isOverruled = false }
        automaticProfile = match?.name

        var reason = isOverruled ? ProfileReason.chosen : (match?.reason ?? .chosen)
        // By its name as the config has it; a profile that has since been deleted, or made a
        // partial one, is no profile.
        let wanted = isOverruled ? overrulingProfile : (match?.name ?? chosenProfile)
        let name = wanted.flatMap { config.profile(named: $0) }.flatMap { $0.partial ? nil : $0.name }
        if name == nil { reason = .chosen }

        // The partial ones go on top of it, whichever it is: those switched on by hand above
        // those the rules ask for.
        let asked = automaticMatches(partial: true)
        partialsOverruled.formIntersection(asked.map(\.name))
        let byHandNames = partialsByHand
        var partials = config.profiles.filter { $0.partial && byHandNames.contains($0.name) }.map { ActivePartial(name: $0.name, reason: .chosen) }
        partials += asked.filter { ask in !partialsOverruled.contains(ask.name) && !partials.contains { $0.name == ask.name } }

        let changed = name != activeProfile
        let came = partials.filter { new in !activePartials.contains { $0.name == new.name } }
        let went = activePartials.filter { old in !partials.contains { $0.name == old.name } }
        // A hero's profile coming on, or going off when the match ends, is news. So is a switch
        // by hand, which otherwise happens blind.
        let isNews = byHand || reason.isGameNews || profileReason.isGameNews
        let partialNews = byHand || (came + went).contains { $0.reason.isGameNews }
        activeProfile = name
        profileReason = reason
        activePartials = partials
        layer = config.layer(for: name, under: partials.map(\.name))
        applyKeyRemap()
        updateTap()
        if changed { log("profile: \(name ?? Profile.defaultName) (\(reason.text))") }
        for partial in came { log("partial profile on: \(partial.name) (\(partial.text))") }
        for partial in went { log("partial profile off: \(partial.name)") }
        func shows(_ isNews: Bool) -> Bool { config.profileNotes == .always || (config.profileNotes == .notApps && isNews) }
        if changed && shows(isNews) {
            let with = partials.isEmpty ? "" : " · with \(partials.map(\.name).joined(separator: ", "))"
            onProfileChanged?(name ?? Profile.defaultName, "Profile · \(reason.text)\(with)")
        } else if let first = came.first, shows(partialNews) {
            onProfileChanged?(came.map(\.name).joined(separator: " + "), "Partial profile on · \(first.text)")
        } else if !went.isEmpty && shows(partialNews) {
            onProfileChanged?(went.map(\.name).joined(separator: " + "), "Partial profile off")
        }
        onStateChanged?()
    }

    private var profileLine: String {
        (["profile: \(activeProfile ?? Profile.defaultName) (\(profileReason.text))"] + activePartials.map { "\($0.name) (\($0.text))" })
            .joined(separator: " + ")
    }

    /// The profile that decides what a button does right now: a partial one that is on and
    /// changes it, else the one in force.
    private func decider(of trigger: Trigger) -> String {
        activePartials.first { config.bindings(of: $0.name)[trigger] != nil }?.name ?? activeProfile ?? Profile.defaultName
    }

    /// Switches profile by hand: a profile's name, "default", "next", "previous", or "auto" to
    /// hand the choice back to the rules. A partial profile's name switches it on, or off if
    /// it is on. Returns a line saying where that leaves things.
    @discardableResult
    func switchProfile(_ word: String) -> String {
        let names: [String?] = [nil] + config.profiles.filter { !$0.partial }.map { Optional($0.name) }
        let target: String?
        switch word.lowercased() {
        case "auto":
            isOverruled = false
            partialsOverruled.removeAll()
            refreshProfile(byHand: true)
            return profileLine
        case "next", "previous":
            guard names.count > 1 else { return "there are no profiles to switch between" }
            let index = names.firstIndex(of: activeProfile) ?? 0
            target = names[(index + (word.lowercased() == "next" ? 1 : names.count - 1)) % names.count]
        case "default":
            target = nil
        default:
            guard let profile = config.profile(named: word) else { return "there is no profile named \"\(word)\"" }
            if profile.partial {
                if activePartials.contains(where: { $0.name == profile.name }) {
                    partialsByHand.removeAll { $0 == profile.name }
                    // Where a rule asks for it, that overrules the rule (see `refreshProfile`).
                    partialsOverruled.insert(profile.name)
                } else if partialsOverruled.remove(profile.name) == nil {
                    partialsByHand.append(profile.name)
                }
                refreshProfile(byHand: true)
                return profileLine
            }
            target = profile.name
        }
        if automaticProfile != nil {
            // A rule is in force: this overrules it, until the rules ask for something else.
            isOverruled = target != automaticProfile
            overrulingProfile = target
        } else {
            chosenProfile = target
        }
        refreshProfile(byHand: true)
        return profileLine
    }

    /// A profile is about to be renamed in the window: follow it, where it is one chosen by
    /// hand. The configuration that has the new name comes next (`updateConfig`).
    func profileRenamed(from old: String, to new: String) {
        if chosenProfile == old { chosenProfile = new }
        if overrulingProfile == old { overrulingProfile = new }
        if partialsByHand.contains(old) { partialsByHand = partialsByHand.map { $0 == old ? new : $0 } }
        if partialsOverruled.remove(old) != nil { partialsOverruled.insert(new) }
        activePartials = activePartials.map { $0.name == old ? ActivePartial(name: new, reason: $0.reason) : $0 }
        if activeProfile == old { activeProfile = new }
        if automaticProfile == old { automaticProfile = new }
    }

    private func profilesText() -> String {
        var lines = [profileLine + (isOverruled ? " — the rules ask for \(automaticProfile ?? Profile.defaultName); `rzmacro profile auto` goes back to them" : "")]
        if !config.autoSwitch { lines.append("automatic switching is off") }
        func line(_ name: String?, _ detail: String) -> String {
            // "*" is the profile in use, "+" a partial one that is on.
            let mark = name == activeProfile ? "*" : (activePartials.contains { $0.name == name } ? "+" : " ")
            return "\(mark) \(name ?? Profile.defaultName)\(detail.isEmpty ? "" : "  — \(detail)")"
        }
        lines.append(line(nil, "\(config.bindings.count) assignments"))
        for profile in config.profiles {
            var rules: [String] = profile.partial ? ["partial"] : []
            if !profile.apps.isEmpty { rules.append("\(profile.whileRunning ? "while running" : "in front"): \(profile.apps.map(appDisplayName).joined(separator: ", "))") }
            if let dota = profile.dota { rules.append("only \(ProfileReason.dota(dota).text)") }
            if !profile.heroes.isEmpty { rules.append("only playing \(profile.heroes.map(DotaHeroes.title).joined(separator: ", "))") }
            if !profile.partial {
                if let base = profile.basedOn, base != Profile.defaultName { rules.append("based on \(base)") }
                if profile.basedOn == nil { rules.append("stands alone") }
            }
            lines.append(line(profile.name, (["\(profile.bindings.count) assignments"] + rules).joined(separator: "; ")))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Keyboard keys

    private var keyboardIDs: Set<DeviceID> {
        Set(devices.devices.filter { $0.kind == .keyboard }.map(\.id))
    }

    /// Tells the keyboard driver what the profile makes of the keyboard's ordinary keys: a key
    /// that is simply another key becomes it; one that does anything else stops being a key
    /// at all, and its assignment is run from `handle` like any button's.
    private func applyKeyRemap() {
        var map: [UInt8: UInt64] = [:]
        for (trigger, assignment) in layer where trigger.isOrdinaryKey && !isRecordingKeys {
            guard case .key(let usage) = trigger.source else { continue }
            if let target = assignment.remapTarget {
                map[usage] = target
            } else if accessibility || assignment.steps.isEmpty {
                // Without Accessibility nothing could be typed in the key's place: leave it a key.
                map[usage] = KeyRemapper.nothing
            }
        }
        let before = remapper.status
        remapper.apply(map, keyboards: keyboardIDs)
        if remapper.status != before { log("keyboard keys: \(remapper.status)") }
    }

    // MARK: Dota 2

    var dotaStatus: DotaWatcher.Status { dota.status }

    /// Adds RZMacro's settings file to the game. Returns what went wrong, if anything did.
    func setUpDota() -> String? {
        do { try dota.install() } catch { return "\(error)" }
        onStateChanged?()
        return nil
    }

    func removeDota() {
        dota.uninstall()
        refreshProfile()
    }

    private func dotaText() -> String {
        let status = dota.status
        guard status.found else { return "dota: the game was not found in the Steam library" }
        guard status.installed else { return "dota: hero detection is not set up (`rzmacro dota setup`, or the Profiles page)" }
        var parts = ["hero detection on"]
        if let error = status.error { parts.append("NOT LISTENING: \(error)") } else if let port = status.port { parts.append("listening on 127.0.0.1:\(port)") }
        if let hero = status.hero {
            parts.append("playing \(DotaHeroes.title(hero))")
        } else if status.receiving {
            parts.append("game connected, no hero")
        } else {
            parts.append(status.running ? "game running but not reporting" : "game not running")
        }
        if status.running { parts.append(status.activity.map { ProfileReason.dota($0).text } ?? "can't tell match from menus (restart the game)") }
        switch DotaWatcher.hasLaunchOption() {
        case true?: break
        case false?: parts.append("launch option \(DotaWatcher.launchOption) is MISSING")
        case nil: parts.append("launch option \(DotaWatcher.launchOption) needed")
        }
        return "dota: " + parts.joined(separator: "; ")
    }

    // MARK: Button events

    private func lookup(_ trigger: Trigger) -> Assignment? { layer[trigger] }

    private func handle(_ device: RazerDevice, _ source: KeySource, _ pressed: Bool) {
        let trigger = Trigger(kind: device.kind, source: source)
        if trigger.isOrdinaryKey {
            // Typing is nobody's business: a key is looked at only if it has been given
            // something to do, or the window is asking which key is meant.
            if !verboseSniffers.isEmpty { broadcast("key     \(trigger.displayName) \(pressed ? "down" : "up")", verboseOnly: true) }
            if pressed, let pick = onKeyPick {
                onKeyPick = nil
                return pick(trigger)
            }
            if pressed && isRecordingKeys { return }
            if pressed, lookup(trigger) != nil {
                shownDown.insert(trigger)
                onButton?(trigger, true)
            } else if !pressed, shownDown.remove(trigger) != nil {
                onButton?(trigger, false)
            }
        } else {
            onButton?(trigger, pressed)
            if !sniffers.isEmpty {
                let name = trigger.displayName == trigger.description ? "" : "  (\(trigger.displayName))"
                // On the way down, what it is about to run, and under which profile.
                let runs = pressed ? lookup(trigger).map { "  → \($0.summary) [\(decider(of: trigger))]" } ?? "" : ""
                broadcast("event   \(trigger) \(pressed ? "down" : "up")\(name)\(runs)")
            }
        }
        if pressed {
            if let binding = lookup(trigger) {
                // A key that is simply another key is the keyboard driver's doing (see applyKeyRemap).
                if trigger.isOrdinaryKey && binding.remapTarget != nil { return }
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
        devices.devices.contains { $0.isRazer && $0.kind == .keyboard && wantedMode(.keyboard) == .driver }
    }

    private var fnHeld: Bool {
        devices.devices.contains { $0.kind == .keyboard && $0.rawDown.contains(0x01) }
    }

    /// The kinds of event that have to be looked at, given what is bound.
    private var tappedEvents: [CGEventType] {
        let bound = layer.keys.filter { $0.kind == .mouse }.map(\.source)
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

    private func broadcast(_ line: String, verboseOnly: Bool = false, at moment: Date = Date()) {
        let stamp = String(format: "%9.3f ", moment.timeIntervalSince(started))
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
        // All that another make's keyboard reports is typing.
        let isTyping = device.kind == .keyboard && interface.isKeyboard && (!device.isRazer || interface.maxInput <= 8 || bytes[0] == 1)
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
        /// "1532:0293".
        let usbID: String
        /// A Razer device — rather than another make's keyboard, of which only the keys are ours.
        let isRazer: Bool
        let firmware: String?
        let inDriverMode: Bool
        /// Names of the keys the device reports down with nothing holding them.
        let stuckKeys: [String]
        let interfaces: [Interface]
    }

    var deviceSummaries: [DeviceSummary] {
        devices.devices.map { device in
            DeviceSummary(
                id: "\(device.id)-\(device.locationID)", kind: device.kind, name: device.name,
                productID: device.productID, usbID: device.id.description, isRazer: device.isRazer, firmware: device.firmware,
                inDriverMode: wantedMode(device.kind) == .driver && device.lastModeError == nil && device.control != nil,
                stuckKeys: Self.stuckKeyNames(device),
                interfaces: device.interfaces.map {
                    .init(id: $0.number, role: $0.role, state: Self.describe($0), ok: $0.openResult == kIOReturnSuccess)
                })
        }
    }

    /// Keyboards plugged in that are not Razer's, looked after or not.
    var otherKeyboards: [DeviceManager.OtherKeyboardSeen] { devices.otherKeyboards }

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
        lines.append("  \(config.bindings.count) bindings, \(config.profiles.count) profiles")
        for trigger in config.bindings.keys.map(\.displayName).sorted() { lines.append("    \(trigger)") }
        lines.append(profileLine)
        lines.append("keyboard keys: \(remapper.status)")
        lines.append(dotaText())
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
            if device.isRazer {
                lines.append("  \(device.kind.rawValue): \(device.name) (\(device.id))  fw \(device.firmware ?? "?")  \(mode)")
            } else {
                lines.append("  keyboard: \(device.name) (\(device.id))  not Razer's: its keys only")
            }
            for interface in device.interfaces {
                lines.append("      if\(interface.number) \(interface.role): \(Self.describe(interface))")
            }
            if device.kind == .mouse {
                // What the mouse says its buttons are typing right now. With no button down this
                // should be nothing; a key that stays is one the mouse has stuck (see KeySlots).
                let down = device.interfaces.reduce(into: Set<Int>()) { if $1.isKeyboard { $0.formUnion($1.usagesDownNow()) } }
                if !down.isEmpty {
                    let names = down.sorted().map { UInt8(exactly: $0).flatMap { KeyboardKeys.byUsage[$0]?.title } ?? String(format: "key %02x", $0) }
                    lines.append("      keys reported down now: \(names.joined(separator: ", "))")
                }
            }
            if let stuck = Self.stuckText(device) { lines.append("      STUCK KEYS: \(stuck)") }
        }
        let unused = devices.otherKeyboards.filter { !devices.wanted.contains($0.id) }
        if !unused.isEmpty {
            lines.append("other keyboards, left alone (Settings turns them on, or `keyboards: [{ id: \"…\" }]` in the config):")
            for keyboard in unused { lines.append("  \(keyboard.name) (\(keyboard.id))\(keyboard.isBuiltIn ? "  built in" : "")") }
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
            reply(configError.map { "config error: \($0)" } ?? "config reloaded: \(config.bindings.count) bindings, \(config.profiles.count) profiles")
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
        case "profile":
            // profile [<name>|default|next|previous|auto]
            guard parts.count > 1 else { return reply(profilesText()) }
            reply(switchProfile(parts.dropFirst().joined(separator: " ")))
        case "dota":
            // dota [setup|remove]
            switch parts[safe: 1] {
            case "setup": reply(setUpDota().map { "error: \($0)" } ?? "\(dotaText())\nrestart Dota 2 for it to take effect")
            case "remove": removeDota(); reply(dotaText())
            default: reply(dotaText())
            }
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
