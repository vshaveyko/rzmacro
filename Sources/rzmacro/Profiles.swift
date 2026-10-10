import AppKit

/// A named set of assignments that takes over from the default ones. It is switched to by
/// hand, or by itself: while an app is in front, while a game is running, or while a certain
/// Dota 2 hero is being played.
struct Profile: Equatable {
    /// What the bindings outside any profile are called, in the app and in `basedOn`.
    static let defaultName = "Default"
    /// Words that mean something else where a profile is named (`{ profile: "next" }`).
    static let reservedNames: Set<String> = ["default", "next", "previous", "auto"]

    var name: String
    var bindings: [Trigger: Assignment] = [:]
    /// Whose assignments apply to the buttons this profile leaves alone: another profile,
    /// "Default", or nil for nobody's — those buttons then do what they do out of the box.
    var basedOn: String? = Profile.defaultName
    /// Bundle identifiers of the apps and games that switch this profile on.
    var apps: [String] = []
    /// On for as long as one of `apps` is running, rather than only while it is in front.
    var whileRunning = false
    /// Dota 2 heroes that switch it on, by internal name without the prefix ("invoker").
    var heroes: [String] = []

    var isAutomatic: Bool { !apps.isEmpty || !heroes.isEmpty }
}

/// When a change of profile is worth a note on screen.
enum ProfileNotes: String, CaseIterable {
    /// Whenever the profile changes.
    case always
    /// When it is changed by hand, or by a Dota hero — but not every time another app comes to
    /// the front, which with a profile per app is every time the app is switched to.
    case notApps = "except-apps"
    case never
}

extension Config {
    func profile(named name: String) -> Profile? {
        profiles.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// A profile followed by the ones it is based on, nearest first. nil stands for the default
    /// bindings, here and wherever a profile is named by an optional.
    func chain(for name: String?) -> [String?] {
        var chain: [String?] = []
        var seen = Set<String>()
        var current = name
        while let name = current, name != Profile.defaultName {
            // Based on itself, by way of others: stop there.
            guard seen.insert(name.lowercased()).inserted else { return chain }
            // Based on a profile that is gone: as if it were based on the default ones.
            guard let profile = profile(named: name) else { break }
            chain.append(profile.name)
            guard let base = profile.basedOn else { return chain }
            current = base
        }
        chain.append(nil)
        return chain
    }

    /// The assignments a profile itself makes.
    func bindings(of name: String?) -> [Trigger: Assignment] {
        guard let name else { return bindings }
        return profile(named: name)?.bindings ?? [:]
    }

    /// Every assignment in force under a profile: its own, then those of what it is based on.
    func layer(for name: String?) -> [Trigger: Assignment] {
        chain(for: name).reversed().reduce(into: [:]) { layer, link in
            layer.merge(bindings(of: link)) { _, nearer in nearer }
        }
    }

    /// What a button does under a profile, and which profile says so.
    func assignment(for trigger: Trigger, in name: String?) -> (assignment: Assignment, from: String?)? {
        for link in chain(for: name) {
            if let assignment = bindings(of: link)[trigger] { return (assignment, link) }
        }
        return nil
    }

    /// The default bindings and every profile's, for questions asked of all of them.
    var allBindings: [[Trigger: Assignment]] { [bindings] + profiles.map(\.bindings) }
}

/// An app's name as the Finder shows it, from its bundle identifier.
func appDisplayName(_ bundleID: String) -> String {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
    let file = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    // Where the app's own name for itself is the file's name written properly ("dota2" is
    // "Dota 2"), that reads better. Where it is something else, the file is what people know.
    func plain(_ text: String) -> String { text.lowercased().filter { $0.isLetter || $0.isNumber } }
    let info = Bundle(url: url)?.infoDictionary
    if let own = (info?["CFBundleDisplayName"] ?? info?["CFBundleName"]) as? String, plain(own) == plain(file) { return own }
    return file
}

/// Whether a running app looks like a game: it says so itself, or a game store installed it.
func isGame(_ app: NSRunningApplication) -> Bool {
    if app.bundleIdentifier == DotaWatcher.bundleID { return true }
    guard let url = app.bundleURL else { return false }
    if url.path.contains("/steamapps/") || url.path.contains("/Epic Games/") { return true }
    guard let info = Bundle(url: url)?.infoDictionary else { return false }
    if (info["LSApplicationCategoryType"] as? String)?.contains("games") == true { return true }
    return info["LSSupportsGameMode"] as? Bool == true || info["GCSupportsGameMode"] as? Bool == true
}
