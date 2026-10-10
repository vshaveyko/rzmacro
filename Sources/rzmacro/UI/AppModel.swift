import AppKit
import ServiceManagement
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case keyboard, mouse, macros, lighting, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keyboard: return "Keyboard"
        case .mouse: return "Mouse"
        case .macros: return "Macros"
        case .lighting: return "Lighting"
        case .settings: return "Settings"
        }
    }

    var icon: String {
        switch self {
        case .keyboard: return "keyboard"
        case .mouse: return "computermouse"
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
            guard config != oldValue, !isSyncing, !isPreviewing else { return }
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
    /// Bundle identifier of the app profile being edited; nil is "all apps".
    @Published var appProfile: String?
    /// The macro open on the Macros page.
    @Published var selectedMacro: String?
    /// Buttons physically held right now, for highlighting.
    @Published var pressed: Set<Trigger> = []
    /// Every special button pressed since launch, so models without a layout can list theirs.
    @Published var seenButtons: [Trigger] = []
    @Published var devices: [Daemon.DeviceSummary] = []
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

    private var isSyncing = false
    /// Showing a configuration that is not the driver's (see `preview`).
    private var isPreviewing = false
    private var pendingSave: DispatchWorkItem?

    init(daemon: Daemon) {
        self.daemon = daemon
        config = daemon.config
        daemon.onStateChanged = { [weak self] in self?.sync() }
        daemon.onButton = { [weak self] trigger, down in self?.button(trigger, down) }
        sync()
        startsAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Pulls the driver's state into the window.
    private func sync() {
        // An edit still waiting to be written wins over whatever prompted this refresh.
        flushSave()
        isSyncing = true
        if !isPreviewing && config != daemon.config { config = daemon.config }
        isSyncing = false
        devices = daemon.deviceSummaries
        inputMonitoring = daemon.inputMonitoring
        accessibility = daemon.accessibility
        configError = daemon.configError
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
        device(kind).map { DeviceProfile.profile(productID: $0.productID, kind: kind) } ?? DeviceProfile.preferred(for: kind)
    }

    /// Every assignable button of a kind: the model's own, then any others that are bound or
    /// have been seen pressed.
    func keys(for kind: DeviceKind) -> [DeviceKey] {
        let listed = profile(for: kind).keys.map { DeviceKey($0, kind: kind) }
        let known = Set(listed.map(\.trigger))
        let bound = Array(config.bindings.keys) + config.apps.values.flatMap(\.keys)
        var seen = Set<Trigger>()
        let unlisted = (bound + seenButtons)
            .filter { $0.kind == kind && !known.contains($0) && seen.insert($0).inserted }
            .sorted { $0.description < $1.description }
            .map(DeviceKey.init(unlisted:))
        return listed + unlisted
    }

    func device(_ kind: DeviceKind) -> Daemon.DeviceSummary? { devices.first { $0.kind == kind } }

    // MARK: Assignments

    /// `profile` is a bundle identifier, or nil for the bindings that apply everywhere.
    func assignment(for trigger: Trigger, profile: String?) -> Assignment? {
        if let profile { return config.apps[profile]?[trigger] }
        return config.bindings[trigger]
    }

    func setAssignment(_ assignment: Assignment?, for trigger: Trigger, profile: String?) {
        if let profile {
            config.apps[profile, default: [:]][trigger] = assignment
        } else {
            config.bindings[trigger] = assignment
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
        updated.apps = updated.apps.mapValues(renamed)
        config = updated
        if selectedMacro == old { selectedMacro = new }
        return true
    }

    func deleteMacro(_ name: String) {
        config.macros[name] = nil
        if selectedMacro == name { selectedMacro = config.macros.keys.sorted().first }
    }

    /// The buttons a macro is assigned to, as short labels: "M3", "Thumb 7 · Safari".
    func usage(ofMacro name: String) -> [String] {
        func label(_ trigger: Trigger) -> String {
            let key = keys(for: trigger.kind).first { $0.trigger == trigger }
            return key.map { $0.group == "Thumb grid" ? "Thumb \($0.label)" : ($0.group == "Volume roller" ? "Roller \($0.label)" : $0.label) } ?? trigger.displayName
        }
        var places = config.bindings.filter { $0.value.steps.contains(.macro(name)) }.map { label($0.key) }
        for (bundleID, bindings) in config.apps {
            places += bindings.filter { $0.value.steps.contains(.macro(name)) }.map { "\(label($0.key)) · \(Self.appName(bundleID))" }
        }
        return places.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: Apps

    static func appName(_ bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }

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
