import AppKit
import ServiceManagement
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case keyboard, mouse, profiles, macros, lighting, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .mouse: return "Mouse"
        case .profiles: return "Profiles"
        case .macros: return "Macros"
        case .lighting: return "Lighting"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
        case .profiles: return "square.stack.3d.up"
        case .macros: return "record.circle"
        case .lighting: return "lightbulb"
        case .settings: return "gearshape"
        }
    }
}

/// The window's view of the driver: an editable copy of the configuration plus live state.
/// Edits are written back (and to the config file) a moment after they stop.
final class AppModel: ObservableObject {
    let daemon: Daemon

    @Published var config: Config {
        didSet {
            guard config != oldValue, !isSyncing, !isPreviewing, savesChanges else { return }
            // Lights follow a slider as it moves; everything else waits for the edit to settle.
            if config.lighting != oldValue.lighting { daemon.previewLighting(config.lighting) }
            scheduleSave()
        }
    }
    @Published var page: Page = .keyboard
    /// The button being edited on each device page.
    @Published var selectedButton: [DeviceKind: Trigger] = [:]
    /// The button under the pointer, in the picture or in the list, so each can light the other.
    @Published var hoveredButton: Trigger?
    /// The profile being edited, on the device pages and the Profiles page; nil is the
    /// default bindings. Use `editing`, which knows about profiles that have been deleted.
    @Published var editingProfile: String?
    /// The profile in force right now (nil: the default bindings), and why.
    @Published var activeProfile: String?
    @Published var profileReason = ""
    /// The profile was chosen by hand over what an app, game or hero asks for.
    @Published var isOverruled = false
    /// The partial profiles that are on right now, on top of that one.
    @Published var activePartials: [Daemon.ActivePartial] = []
    /// The partial profiles switched off by hand, whatever their rules ask for.
    @Published var partialsOff: Set<String> = []
    /// The partial profiles that are off only for their app not being in front, and that app.
    @Published var awaitedApps: [String: String] = [:]
    @Published var dota = DotaWatcher.Status()
    /// Whether Dota 2 is started with the launch option hero detection needs; nil if unknown.
    @Published var dotaLaunchOption: Bool?
    @Published var dotaError: String?
    /// Waiting for a key to be pressed on the keyboard, to select it.
    @Published var isPickingKey = false
    private var pickMonitor: Any?
    /// The macro open on the Macros page.
    @Published var selectedMacro: String?
    /// Buttons physically held right now, for highlighting.
    @Published var pressed: Set<Trigger> = []
    /// Every special button pressed since launch, so models without a layout can list theirs.
    @Published var seenButtons: [Trigger] = []
    @Published var devices: [Daemon.DeviceSummary] = []
    /// Keyboards plugged in that are not Razer's, looked after or not.
    @Published var otherKeyboards: [DeviceManager.OtherKeyboardSeen] = []
    /// Which device a page shows, where several of its kind are connected (a summary's id).
    @Published var shownDevice: [DeviceKind: String] = [:]
    @Published var inputMonitoring = false
    @Published var accessibility = false
    @Published var configError: String?
    @Published var startsAtLogin = false
    @Published var loginItemError: String?
    /// Show the manufacturer's product photo, where one has been downloaded, instead of the drawing.
    @Published var showsPhotos = UserDefaults.standard.bool(forKey: "showsPhotos") {
        didSet { UserDefaults.standard.set(showsPhotos, forKey: "showsPhotos") }
    }
    @Published var isDownloadingPhoto = false
    @Published var photoError: String?

    /// Off for a window that is only there to be looked at (`rzmacro render`): nothing done in
    /// it reaches the driver or the config file.
    var savesChanges = true
    private var isCapturingKeys = false
    private var isSyncing = false
    /// Showing a configuration that is not the driver's (see `preview`).
    private var isPreviewing = false
    private var pendingSave: DispatchWorkItem?

    init(daemon: Daemon) {
        self.daemon = daemon
        config = daemon.config
        daemon.onStateChanged = { [weak self] in self?.sync() }
        daemon.onButton = { [weak self] trigger, down in self?.button(trigger, down) }
        // While keys are being recorded in the window — and the window is where the typing
        // goes — the keyboard's keys must be themselves (see `Daemon.isRecordingKeys`).
        KeyCapture.onActivity = { [weak self] capturing in
            self?.isCapturingKeys = capturing
            self?.updateRecording()
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in self?.updateRecording() }
        }
        sync()
        startsAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func updateRecording() {
        daemon.isRecordingKeys = isCapturingKeys && NSApplication.shared.isActive
    }

    /// Pulls the driver's state into the window.
    private func sync() {
        // An edit still waiting to be written wins over whatever prompted this refresh.
        flushSave()
        isSyncing = true
        if !isPreviewing && config != daemon.config { config = daemon.config }
        isSyncing = false
        devices = daemon.deviceSummaries
        otherKeyboards = daemon.otherKeyboards
        inputMonitoring = daemon.inputMonitoring
        accessibility = daemon.accessibility
        configError = daemon.configError
        activeProfile = daemon.activeProfile
        profileReason = daemon.profileReason.text
        isOverruled = daemon.isOverruled
        activePartials = daemon.activePartials
        partialsOff = Set(daemon.partialsOff)
        awaitedApps = daemon.awaitedApps
        dota = daemon.dotaStatus
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private func flushSave() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        daemon.updateConfig(config)
    }

    /// Developer aid for screenshots: displays `config` without it reaching the driver or the
    /// file. Pass nil to go back to the real one.
    func preview(_ config: Config?) {
        flushSave()
        isPreviewing = true
        self.config = config ?? daemon.config
        isPreviewing = config != nil
    }

    private func button(_ trigger: Trigger, _ down: Bool) {
        if down { pressed.insert(trigger) } else { pressed.remove(trigger) }
        // An ordinary key lights up while held, no more: it is typed on all the time.
        if trigger.isTyped { return }
        // Clicks and the wheel are in constant use: they shouldn't change what is selected.
        // Fn is the keyboard's own layer key.
        if case .button = trigger.source { return }
        if case .wheel = trigger.source { return }
        if trigger.source == .raw(0x01) && trigger.kind == .keyboard { return }
        guard down else { return }
        if !seenButtons.contains(trigger) { seenButtons.append(trigger) }
        // Pressing a button on the device is the quickest way to pick it in the window.
        if page == (trigger.kind == .keyboard ? .keyboard : .mouse) { selectedButton[trigger.kind] = trigger }
    }

    // MARK: Product photos

    /// The photo for a model, if the user wants photos and this one has been downloaded.
    func photo(for picture: DeviceProfile.Picture) -> NSImage? {
        showsPhotos ? DeviceStage.image(named: picture.file) : nil
    }

    /// Switches to the product photo, downloading it from the manufacturer first if need be.
    func usePhoto(_ picture: DeviceProfile.Picture) {
        photoError = nil
        if DeviceStage.image(named: picture.file) != nil {
            showsPhotos = true
            return
        }
        guard let url = URL(string: picture.url) else { return }
        isDownloadingPhoto = true
        URLSession.shared.dataTask(with: url) { data, _, error in
            DispatchQueue.main.async {
                self.isDownloadingPhoto = false
                guard let data, NSImage(data: data) != nil else {
                    self.photoError = error?.localizedDescription ?? "That was not a picture."
                    return
                }
                do {
                    try FileManager.default.createDirectory(at: Paths.pictures, withIntermediateDirectories: true)
                    try data.write(to: Paths.pictures.appendingPathComponent(picture.file))
                    self.showsPhotos = true
                } catch {
                    self.photoError = error.localizedDescription
                }
            }
        }.resume()
    }

    // MARK: Buttons

    /// The connected model's profile; with nothing plugged in, the one the page usually shows.
    func profile(for kind: DeviceKind) -> DeviceProfile {
        guard let device = device(kind) else { return DeviceProfile.preferred(for: kind) }
        // Another make's keyboard has no special buttons, whatever its product number says.
        return device.isRazer ? DeviceProfile.profile(productID: device.productID, kind: kind) : DeviceProfile.generic(kind)
    }

    /// Every button of a kind worth listing: the model's special ones, any others that are
    /// bound or have been seen pressed, and — of a keyboard's ordinary keys — the ones the
    /// profile being edited gives something to do, plus the one selected, so that it can be.
    func keys(for kind: DeviceKind) -> [DeviceKey] {
        let listed = profile(for: kind).keys.map { DeviceKey($0, kind: kind) }
        let known = Set(listed.map(\.trigger))
        var seen = Set<Trigger>()
        // Another make's keyboard has none of the special buttons the Razer one's are bound to.
        let special = device(kind)?.isRazer == false ? [] : (config.allBindings.flatMap(\.keys) + seenButtons)
            .filter { $0.kind == kind && !$0.isTyped && !known.contains($0) && seen.insert($0).inserted }
            .sorted { $0.description < $1.description }
        // Keys first, then the combinations of them.
        let ordinary = (Array(shownLayer(for: editing).keys) + (selectedButton[kind].map { [$0] } ?? []))
            .filter { $0.kind == kind && $0.isTyped && seen.insert($0).inserted }
            .sorted { ($0.isCombination ? 1 : 0, $0.description) < ($1.isCombination ? 1 : 0, $1.description) }
        return listed + (special + ordinary).map(DeviceKey.init(unlisted:))
    }

    /// Selects the next ordinary key pressed on the keyboard, instead of that key doing
    /// anything — or, pressed with modifiers held, the combination.
    func pickKey() {
        isPickingKey = true
        // What is pressed must not reach the window: ⌘W would close it, ⌘Q quit.
        if pickMonitor == nil {
            pickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                // The driver hears of the key before the window does: wait for it to come up.
                if event.type == .keyUp, self?.isPickingKey == false { self?.stopPickMonitor() }
                return nil
            }
        }
        daemon.onKeyPick = { [weak self] trigger in
            guard let self else { return }
            self.isPickingKey = false
            self.selectedButton[.keyboard] = trigger
            // A modifier picked by itself sends no key-up to wait for.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { if !self.isPickingKey { self.stopPickMonitor() } }
        }
    }

    func cancelKeyPick() {
        daemon.onKeyPick = nil
        isPickingKey = false
        stopPickMonitor()
    }

    private func stopPickMonitor() {
        if let pickMonitor { NSEvent.removeMonitor(pickMonitor) }
        pickMonitor = nil
    }

    func devices(of kind: DeviceKind) -> [Daemon.DeviceSummary] { devices.filter { $0.kind == kind } }

    /// The device a page shows: the one chosen, else a Razer one, else whatever there is.
    func device(_ kind: DeviceKind) -> Daemon.DeviceSummary? {
        let candidates = devices(of: kind)
        return candidates.first { $0.id == shownDevice[kind] } ?? candidates.first(where: \.isRazer) ?? candidates.first
    }

    // MARK: Other keyboards

    /// A keyboard that is not Razer's: one that is plugged in, or one RZMacro has been told to
    /// look after and that isn't.
    struct OtherKeyboardRow: Identifiable {
        let id: DeviceID
        let name: String
        let isBuiltIn: Bool
        let isConnected: Bool
        let isOn: Bool
    }

    var otherKeyboardRows: [OtherKeyboardRow] {
        let wanted = Set(config.keyboards.map(\.id))
        let plugged = otherKeyboards.map { OtherKeyboardRow(id: $0.id, name: $0.name, isBuiltIn: $0.isBuiltIn, isConnected: true, isOn: wanted.contains($0.id)) }
        let away = config.keyboards.filter { keyboard in !otherKeyboards.contains { $0.id == keyboard.id } }
            .map { OtherKeyboardRow(id: $0.id, name: $0.name, isBuiltIn: false, isConnected: false, isOn: true) }
        return plugged + away
    }

    /// Starts or stops looking after a keyboard that is not Razer's.
    func setOtherKeyboard(_ row: OtherKeyboardRow, on: Bool) {
        config.keyboards.removeAll { $0.id == row.id }
        if on { config.keyboards.append(OtherKeyboard(id: row.id, name: row.name)) }
    }

    /// How much of a keyboard to draw for a device. Razer's are full size; another make's is
    /// what its entry says.
    func shape(of device: Daemon.DeviceSummary?) -> KeyboardShape {
        guard let device, !device.isRazer else { return .full }
        return config.keyboards.first { $0.id.description == device.usbID }?.shape ?? .full
    }

    func setShape(_ shape: KeyboardShape, of device: Daemon.DeviceSummary) {
        guard let index = config.keyboards.firstIndex(where: { $0.id.description == device.usbID }) else { return }
        config.keyboards[index].shape = shape
    }

    // MARK: Assignments

    /// What a profile itself assigns to a button; `profile` nil is the default bindings.
    func assignment(for trigger: Trigger, profile: String?) -> Assignment? {
        config.bindings(of: profile)[trigger]
    }

    /// What a button does under a profile, counting what the profile is based on, and which
    /// profile says so. A partial profile is based on whichever profile is in use at the moment.
    func effective(_ trigger: Trigger, profile: String?) -> (assignment: Assignment, from: String?)? {
        if let profile, isPartial(profile), config.bindings(of: profile)[trigger] == nil {
            return config.assignment(for: trigger, in: activeProfile)
        }
        return config.assignment(for: trigger, in: profile)
    }

    /// The partial profile that decides a button right now over the profile given, where that
    /// one is in use: one that is on, and above it.
    func partialOver(_ trigger: Trigger, profile: String?) -> (name: String, assignment: Assignment)? {
        let above: ArraySlice<Daemon.ActivePartial>
        if let index = activePartials.firstIndex(where: { $0.name == profile }) {
            above = activePartials[..<index]
        } else if profile == activeProfile {
            above = activePartials[...]
        } else {
            return nil
        }
        for partial in above {
            if let assignment = config.bindings(of: partial.name)[trigger] { return (partial.name, assignment) }
        }
        return nil
    }

    /// Every assignment `effective` would report under a profile.
    func shownLayer(for profile: String?) -> [Trigger: Assignment] {
        guard let profile, isPartial(profile) else { return config.layer(for: profile) }
        return config.layer(for: activeProfile, under: [profile])
    }

    func setAssignment(_ assignment: Assignment?, for trigger: Trigger, profile: String?) {
        guard let profile else { return config.bindings[trigger] = assignment }
        updateProfile(profile) { $0.bindings[trigger] = assignment }
    }

    // MARK: ⌘Q

    /// What ⌘Q does while a profile is on: a quick way to the assignment that keeps a game
    /// from being quit by the key next to its Alt.
    enum QuitKey: Hashable {
        case quits, sendsOption, nothing
        /// Given something else to do, on the keyboard page.
        case other
    }

    static let quitCombination = Trigger(kind: .keyboard, source: KeySource(combo: try! Chord("cmd+q"))!)
    /// ⌥Q for as long as it is held, as the key itself would be.
    static let optionQ = Assignment(steps: [.tap(try! Chord("alt+q"))], hold: true)

    func quitKey(in profile: String) -> QuitKey {
        guard let assignment = config.bindings(of: profile)[Self.quitCombination] else { return .quits }
        if assignment == Self.optionQ { return .sendsOption }
        return assignment.steps.isEmpty ? .nothing : .other
    }

    func setQuitKey(_ value: QuitKey, in profile: String) {
        switch value {
        case .quits: setAssignment(nil, for: Self.quitCombination, profile: profile)
        case .sendsOption: setAssignment(Self.optionQ, for: Self.quitCombination, profile: profile)
        case .nothing: setAssignment(Assignment(steps: []), for: Self.quitCombination, profile: profile)
        case .other: break
        }
    }

    // MARK: Profiles

    /// The profile being edited, if it still exists; nil is the default bindings.
    var editing: String? { editingProfile.flatMap { config.profile(named: $0)?.name } }

    func updateProfile(_ name: String, _ change: (inout Profile) -> Void) {
        guard let index = config.profiles.firstIndex(where: { $0.name == name }) else { return }
        change(&config.profiles[index])
    }

    func isPartial(_ name: String) -> Bool { config.profile(named: name)?.partial == true }

    /// Why a partial profile is on, or nil if it is off.
    func partialReason(_ name: String) -> String? { activePartials.first { $0.name == name }?.text }

    /// How a partial profile is switched: by its rules, or by hand whatever they ask for.
    func partialSwitch(of name: String) -> Daemon.PartialSwitch {
        if activePartials.contains(where: { $0.name == name && $0.reason == .chosen }) { return .on }
        return partialsOff.contains(name) ? .off : .automatic
    }

    func setPartialSwitch(_ name: String, to value: Daemon.PartialSwitch) {
        flushSave()
        daemon.setPartialSwitch(name, to: value)
    }

    /// What a partial profile is doing right now and why, in a few words. One that goes by the
    /// app in front is off while this window is: said so, it does not look broken.
    func partialStatus(of profile: Profile) -> (text: String, isOn: Bool, isWaiting: Bool) {
        if let reason = partialReason(profile.name) { return ("On now — \(reason)", true, false) }
        if partialsOff.contains(profile.name) { return ("Off — switched off by hand", false, false) }
        if let app = awaitedApps[profile.name] {
            return ("Off now — on when \(Self.appName(app)) is \(profile.whileRunning ? "running" : "in front")", false, true)
        }
        return ("Off", false, false)
    }

    /// Whether a profile is doing anything right now: the one in use, or a partial one that is on.
    func isInUse(_ name: String?) -> Bool { activeProfile == name || activePartials.contains { $0.name == name } }

    /// Makes a profile a partial one, or a whole one again.
    func setPartial(_ name: String, _ partial: Bool) {
        guard let profile = config.profile(named: name), profile.partial != partial else { return }
        var updated = config
        updated.profiles = updated.profiles.map { other in
            var copy = other
            if other.name == profile.name {
                copy.partial = partial
                copy.basedOn = Profile.defaultName
            } else if partial, other.basedOn == profile.name {
                // Nothing can be based on a partial profile: on what it was based on, then.
                copy.basedOn = profile.basedOn
            }
            return copy
        }
        config = updated
    }

    /// Adds a profile and makes it the one being edited. A taken name gets a number.
    @discardableResult
    func addProfile(named wanted: String? = nil, apps: [String] = [], heroes: [String] = [], partial: Bool = false) -> String {
        let base = wanted ?? (partial ? "Partial" : "Profile")
        var name = wanted ?? "\(base) 1"
        var suffix = 2
        while config.profile(named: name) != nil || Profile.reservedNames.contains(name.lowercased()) {
            name = "\(base) \(suffix)"
            suffix += 1
        }
        var profile = Profile(name: name, partial: partial, apps: apps, heroes: heroes)
        profile.tidyDotaRules()
        // A hero's profile builds on the game's, where there is one.
        if !partial, !heroes.isEmpty, let game = config.profiles.first(where: { !$0.partial && $0.heroes.isEmpty && $0.apps.contains(DotaWatcher.bundleID) }) {
            profile.basedOn = game.name
        }
        config.profiles.append(profile)
        editingProfile = name
        return name
    }

    /// Renames a profile and everything that refers to it. Returns false if the name can't be used.
    func renameProfile(_ old: String, to new: String) -> Bool {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old, !Profile.reservedNames.contains(new.lowercased()),
              config.profile(named: new).map({ $0.name == old }) ?? true,
              let index = config.profiles.firstIndex(where: { $0.name == old }) else { return false }
        func renamed(_ steps: [Step]) -> [Step] { steps.map { $0 == .profile(old) ? .profile(new) : $0 } }
        func renamed(_ bindings: [Trigger: Assignment]) -> [Trigger: Assignment] {
            bindings.mapValues { var copy = $0; copy.steps = renamed($0.steps); return copy }
        }
        var updated = config
        updated.profiles[index].name = new
        updated.bindings = renamed(updated.bindings)
        updated.macros = updated.macros.mapValues { var copy = $0; copy.steps = renamed($0.steps); return copy }
        updated.profiles = updated.profiles.map { profile in
            var copy = profile
            copy.bindings = renamed(profile.bindings)
            if profile.basedOn == old { copy.basedOn = new }
            return copy
        }
        config = updated
        if editingProfile == old { editingProfile = new }
        // The driver knows the profiles in use by name: hand it the new name, then the new configuration.
        daemon.profileRenamed(from: old, to: new)
        flushSave()
        return true
    }

    func deleteProfile(_ name: String) {
        guard let profile = config.profile(named: name) else { return }
        var updated = config
        updated.profiles.removeAll { $0.name == profile.name }
        // Profiles built on it are built on whatever it was built on.
        updated.profiles = updated.profiles.map { var copy = $0; if $0.basedOn == profile.name { copy.basedOn = profile.basedOn }; return copy }
        config = updated
        if editingProfile == profile.name { editingProfile = nil }
    }

    /// Earlier profiles win when several ask to be switched on.
    func moveProfile(_ name: String, by offset: Int) {
        guard let index = config.profiles.firstIndex(where: { $0.name == name }), config.profiles.indices.contains(index + offset) else { return }
        config.profiles.swapAt(index, index + offset)
    }

    /// Switches to a profile by hand, now. A partial profile is switched on, or off if it is on.
    func useProfile(_ name: String?) {
        flushSave()
        daemon.switchProfile(name ?? "default")
    }

    /// Lets apps, games and heroes choose the profile again.
    func resumeAutomaticProfile() {
        daemon.switchProfile("auto")
    }

    /// One line on when a profile comes on by itself: "Dota 2 · in a match · Invoker, Meepo".
    func rules(of profile: Profile) -> String {
        var parts: [String] = []
        if !profile.apps.isEmpty { parts.append(profile.apps.map(Self.appName).joined(separator: ", ") + (profile.whileRunning ? " running" : "")) }
        if let dota = profile.dota { parts.append(dota == .playing ? "in a match" : "in the menus") }
        if !profile.heroes.isEmpty { parts.append(profile.heroes.map(DotaHeroes.title).joined(separator: ", ")) }
        if profile.partial { return parts.isEmpty ? "Partial · switched by hand" : "Partial · " + parts.joined(separator: " · ") }
        return parts.isEmpty ? "Switched to by hand" : parts.joined(separator: " · ")
    }

    // MARK: Dota 2

    func setUpDota() {
        dotaError = daemon.setUpDota()
        refreshDotaLaunchOption()
    }

    func removeDota() {
        daemon.removeDota()
        dotaError = nil
    }

    /// Steam's settings are a file to read, and the running game a process to ask: done when
    /// the answer is about to be shown, not on every refresh.
    func refreshDotaLaunchOption() {
        DispatchQueue.global(qos: .utility).async {
            let has = DotaWatcher.hasLaunchOption()
            DispatchQueue.main.async { if self.dotaLaunchOption != has { self.dotaLaunchOption = has } }
        }
    }

    // MARK: Macros

    func addMacro() -> String {
        var index = config.macros.count + 1
        while config.macros["Macro \(index)"] != nil { index += 1 }
        let name = "Macro \(index)"
        config.macros[name] = Macro()
        selectedMacro = name
        return name
    }

    /// Renames a macro and everything that refers to it. Returns false if the name is taken.
    func renameMacro(_ old: String, to new: String) -> Bool {
        let new = new.trimmingCharacters(in: .whitespaces)
        guard !new.isEmpty, new != old, config.macros[new] == nil, let macro = config.macros[old] else { return false }
        func renamed(_ steps: [Step]) -> [Step] { steps.map { $0 == .macro(old) ? .macro(new) : $0 } }
        func renamed(_ bindings: [Trigger: Assignment]) -> [Trigger: Assignment] {
            bindings.mapValues { var copy = $0; copy.steps = renamed($0.steps); return copy }
        }
        var updated = config
        updated.macros[old] = nil
        updated.macros[new] = macro
        updated.macros = updated.macros.mapValues { var copy = $0; copy.steps = renamed($0.steps); return copy }
        updated.bindings = renamed(updated.bindings)
        updated.profiles = updated.profiles.map { var copy = $0; copy.bindings = renamed($0.bindings); return copy }
        config = updated
        if selectedMacro == old { selectedMacro = new }
        return true
    }

    func deleteMacro(_ name: String) {
        config.macros[name] = nil
        if selectedMacro == name { selectedMacro = config.macros.keys.sorted().first }
    }

    /// The buttons a macro is assigned to, as short labels: "M3", "Thumb 7 · Dota".
    func usage(ofMacro name: String) -> [String] {
        func label(_ trigger: Trigger) -> String {
            let key = keys(for: trigger.kind).first { $0.trigger == trigger }
            return key.map { $0.group == "Thumb grid" ? "Thumb \($0.label)" : ($0.group == "Volume roller" ? "Roller \($0.label)" : $0.label) } ?? trigger.displayName
        }
        var places = config.bindings.filter { $0.value.steps.contains(.macro(name)) }.map { label($0.key) }
        for profile in config.profiles {
            places += profile.bindings.filter { $0.value.steps.contains(.macro(name)) }.map { "\(label($0.key)) · \(profile.name)" }
        }
        return places.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Apps

    static func appName(_ bundleID: String) -> String { appDisplayName(bundleID) }

    // MARK: Login item

    func setStartsAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginItemError = nil
        } catch {
            loginItemError = error.localizedDescription
        }
        startsAtLogin = SMAppService.mainApp.status == .enabled
    }
}
