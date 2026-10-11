import AppKit

/// A named set of assignments that takes over from the default ones. It is switched to by
/// hand, or by itself: while an app is in front or a game is running — and for Dota 2, if it
/// says so, only during a match, only in the menus, or only while certain heroes are played.
///
/// A partial profile takes over nothing: it is switched on and off the same ways, and while
/// on changes only its own buttons, on top of whichever profile is in use. Several can be on.
struct Profile: Equatable {
    /// What the bindings outside any profile are called, in the app and in `basedOn`.
    static let defaultName = "Default"
    /// Words that mean something else where a profile is named (`{ profile: "next" }`).
    static let reservedNames: Set<String> = ["default", "next", "previous", "auto"]

    var name: String
    var bindings: [Trigger: Assignment] = [:]
    /// Goes on top of the profile in use rather than being it. Its own `basedOn` then says
    /// nothing: the buttons it leaves alone are that profile's, whichever it is at the time.
    var partial = false
    /// Whose assignments apply to the buttons this profile leaves alone: another profile,
    /// "Default", or nil for nobody's — those buttons then do what they do out of the box.
    var basedOn: String? = Profile.defaultName
    /// Bundle identifiers of the apps and games that switch this profile on.
    var apps: [String] = []
    /// On for as long as one of `apps` is running, rather than only while it is in front.
    var whileRunning = false
    /// Asks more of Dota 2, where that is among `apps`: with heroes listed, that one of them is
    /// being played. By internal name without the prefix ("invoker").
    var heroes: [String] = []
    /// And likewise that a match is being played, or that the game is in its menus.
    var dota: DotaActivity?

    var isAutomatic: Bool { !apps.isEmpty }

    /// Heroes and matches are Dota's: a profile that asks for them is one for the game.
    mutating func tidyDotaRules() {
        let isForDota = apps.contains(DotaWatcher.bundleID)
        if !isForDota && (!heroes.isEmpty || dota != nil) { apps.append(DotaWatcher.bundleID) }
    }
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
            // A partial profile is based on nothing of its own.
            guard !profile.partial, let base = profile.basedOn else { return chain }
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

    /// Every assignment in force with a profile in use and partial profiles on top of it, the
    /// one that wins a button several of them change first.
    func layer(for name: String?, under partials: [String]) -> [Trigger: Assignment] {
        partials.reversed().reduce(into: layer(for: name)) { layer, partial in
            layer.merge(bindings(of: partial)) { _, upper in upper }
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
