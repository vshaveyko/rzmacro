import Foundation

/// Everything the user can configure. Lives in ~/.config/rzmacro/config.json5; the app reads
/// and writes it, and it stays hand-editable (JSON5 — comments survive until the app next saves).
struct Config: Equatable {
    /// Whether to switch each device kind into Razer driver mode while the driver runs.
    var driverMode: [DeviceKind: Bool] = [.keyboard: true, .mouse: true]
    /// Keyboards that are not Razer's, to look after as well: only the ones listed here.
    var keyboards: [OtherKeyboard] = []
    /// What buttons do when no profile says otherwise: the "Default" profile.
    var bindings: [Trigger: Assignment] = [:]
    /// Named sets of assignments. Where several ask to be switched on at once, the earlier wins;
    /// partial ones are all on together, and there the earlier wins a button two of them change.
    var profiles: [Profile] = []
    /// Whether apps, games and Dota heroes may switch profiles by themselves.
    var autoSwitch = true
    /// When to show the profile's name on screen for a moment as it changes.
    var profileNotes = ProfileNotes.notApps
    /// The macro library: named step lists that assignments refer to with `{ macro: "name" }`.
    var macros: [String: Macro] = [:]
    /// How macros and shortcuts press keys, in milliseconds: each key is held this long and
    /// followed by the same pause. 0 is as fast as possible. A macro can override it.
    var keyDelay = 0
    /// nil leaves the devices' lighting alone.
    var lighting: LightSpec?

    /// What a fresh install starts with.
    static let initial: Config = {
        var config = Config()
        config.lighting = LightSpec(kind: .spectrum, colors: [], period: 12, reverse: false, brightness: 0.8)
        return config
    }()

    // MARK: Reading

    static func load(from url: URL) throws -> Config {
        guard let data = try? Data(contentsOf: url) else { throw ConfigError("cannot read \(url.path)") }
        return try parse(data)
    }

    static func parse(_ data: Data) throws -> Config {
        let root: Any
        do {
            root = try JSONSerialization.jsonObject(with: data, options: [.json5Allowed])
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String
            throw ConfigError("syntax error: \(detail ?? error.localizedDescription)")
        }
        guard let object = root as? [String: Any] else { throw ConfigError("top level must be an object { … }") }

        var config = Config()
        /// `apps: { bundle id: bindings }`, from before profiles had names.
        var perApp: [Profile] = []
        for (key, value) in object {
            switch key {
            case "devices":
                guard let devices = value as? [String: Any] else { throw ConfigError("devices: expected an object") }
                for (name, options) in devices {
                    guard let kind = DeviceKind(configName: name) else { throw ConfigError("devices.\(name): expected \"keyboard\" or \"mouse\"") }
                    guard let options = options as? [String: Any] else { throw ConfigError("devices.\(name): expected an object") }
                    for (option, optionValue) in options {
                        guard option == "driverMode", let flag = optionValue as? Bool else {
                            throw ConfigError("devices.\(name).\(option): only `driverMode: true|false` is supported")
                        }
                        config.driverMode[kind] = flag
                    }
                }
            case "keyboards":
                guard let keyboards = value as? [Any] else { throw ConfigError("keyboards: expected a list [ { id: \"05ac:024f\" }, … ]") }
                for (index, entry) in keyboards.enumerated() {
                    let keyboard = try parseKeyboard(entry, path: "keyboards[\(index)]")
                    // Listed twice is listed once.
                    if !config.keyboards.contains(where: { $0.id == keyboard.id }) { config.keyboards.append(keyboard) }
                }
            case "bindings":
                config.bindings = try parseBindings(value, path: "bindings")
            case "profiles":
                guard let profiles = value as? [Any] else { throw ConfigError("profiles: expected a list [ { name: …, bindings: { … } }, … ]") }
                config.profiles = try profiles.enumerated().map { try parseProfile($1, path: "profiles[\($0)]") }
            case "apps":
                guard let apps = value as? [String: Any] else { throw ConfigError("apps: expected an object keyed by bundle id") }
                for (bundleID, bindings) in apps.sorted(by: { $0.key < $1.key }) {
                    // Named after the app, as far as its identifier tells: "com.apple.Safari" is "Safari".
                    let name = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
                    perApp.append(Profile(name: name, bindings: try parseBindings(bindings, path: "apps.\(bundleID)"), apps: [bundleID]))
                }
            case "autoSwitch":
                guard let flag = value as? Bool else { throw ConfigError("autoSwitch: expected true or false") }
                config.autoSwitch = flag
            case "profileNotes":
                guard let notes = (value as? String).flatMap(ProfileNotes.init(rawValue:)) else {
                    throw ConfigError("profileNotes: expected one of \(ProfileNotes.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                config.profileNotes = notes
            case "macros":
                guard let macros = value as? [String: Any] else { throw ConfigError("macros: expected an object keyed by macro name") }
                for (name, value) in macros {
                    // A list of steps, or { steps: […], keyDelay: 30 } for a macro with its own key speed.
                    let object = value as? [String: Any]
                    guard let steps = (value as? [Any]) ?? (object?["steps"] as? [Any]) else { throw ConfigError("macros.\(name): expected a list of steps") }
                    var macro = Macro(steps: try steps.enumerated().map { try parseStep($1, path: "macros.\(name)[\($0)]") })
                    if let delay = object?["keyDelay"] { macro.keyDelay = try parseKeyDelay(delay, path: "macros.\(name).keyDelay") }
                    if let extra = object?.keys.first(where: { $0 != "steps" && $0 != "keyDelay" }) {
                        throw ConfigError("macros.\(name): unknown option \"\(extra)\" (expected steps, keyDelay)")
                    }
                    config.macros[name] = macro
                }
            case "keyDelay":
                config.keyDelay = try parseKeyDelay(value, path: "keyDelay")
            case "lighting":
                guard let options = value as? [String: Any] else { throw ConfigError("lighting: expected an object") }
                do { config.lighting = try LightSpec(config: options) } catch { throw ConfigError("lighting: \(error)") }
            default:
                throw ConfigError("unknown top-level key \"\(key)\" (expected devices, keyboards, bindings, profiles, macros, keyDelay, lighting, autoSwitch, profileNotes)")
            }
        }

        for var profile in perApp {
            let base = profile.name
            var suffix = 2
            while config.profile(named: profile.name) != nil || Profile.reservedNames.contains(profile.name.lowercased()) {
                profile.name = "\(base) \(suffix)"
                suffix += 1
            }
            config.profiles.append(profile)
        }
        for (index, profile) in config.profiles.enumerated() {
            if config.profiles.prefix(index).contains(where: { $0.name.caseInsensitiveCompare(profile.name) == .orderedSame }) {
                throw ConfigError("profiles[\(index)]: there is already a profile named \"\(profile.name)\"")
            }
            if let base = profile.basedOn, base != Profile.defaultName {
                guard let based = config.profile(named: base) else {
                    throw ConfigError("profiles[\(index)].basedOn: there is no profile named \"\(base)\"")
                }
                if based.partial {
                    throw ConfigError("profiles[\(index)].basedOn: \"\(based.name)\" is a partial profile, and nothing can be based on one")
                }
            }
        }
        return config
    }

    private static func parseProfile(_ value: Any, path: String) throws -> Profile {
        guard let object = value as? [String: Any] else { throw ConfigError("\(path): expected an object { name: …, bindings: { … } }") }
        guard let name = (object["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw ConfigError("\(path).name: every profile needs a name")
        }
        guard !Profile.reservedNames.contains(name.lowercased()) else {
            throw ConfigError("\(path).name: \"\(name)\" means something else — pick another name")
        }
        func strings(_ value: Any, _ option: String) throws -> [String] {
            if let one = value as? String { return [one] }
            guard let list = value as? [String] else { throw ConfigError("\(path).\(option): expected a list of names") }
            return list
        }
        var profile = Profile(name: name)
        for (option, value) in object {
            switch option {
            case "name":
                break
            case "bindings":
                profile.bindings = try parseBindings(value, path: "\(path).bindings")
            case "basedOn":
                // A profile's name, "Default", or null for a profile that stands alone.
                if value is NSNull {
                    profile.basedOn = nil
                } else if let base = value as? String {
                    profile.basedOn = base.lowercased() == "default" ? Profile.defaultName : base
                } else {
                    throw ConfigError("\(path).basedOn: expected a profile's name, \"Default\" or null")
                }
            case "partial":
                guard let flag = value as? Bool else { throw ConfigError("\(path).partial: expected true or false") }
                profile.partial = flag
            case "apps":
                profile.apps = try strings(value, option)
            case "whileRunning":
                guard let flag = value as? Bool else { throw ConfigError("\(path).whileRunning: expected true or false") }
                profile.whileRunning = flag
            case "heroes":
                profile.heroes = try strings(value, option).map(DotaHeroes.name(matching:))
            case "dota":
                guard let activity = (value as? String).flatMap(DotaActivity.init(rawValue:)) else {
                    throw ConfigError("\(path).dota: expected \"playing\" (during a match) or \"menu\"")
                }
                profile.dota = activity
            default:
                throw ConfigError("\(path): unknown option \"\(option)\" (expected name, bindings, partial, basedOn, apps, whileRunning, heroes, dota)")
            }
        }
        // `heroes` used to be a rule of its own; it is the game's, as is `dota`.
        profile.tidyDotaRules()
        if profile.partial && object["basedOn"] != nil {
            throw ConfigError("\(path).basedOn: a partial profile goes on top of whichever profile is in use — it is not based on one")
        }
        return profile
    }

    private static func parseKeyDelay(_ value: Any, path: String) throws -> Int {
        guard let ms = value as? Int, (0...2000).contains(ms) else { throw ConfigError("\(path): expected milliseconds, 0…2000") }
        return ms
    }

    private static func parseBindings(_ value: Any, path: String) throws -> [Trigger: Assignment] {
        guard let object = value as? [String: Any] else { throw ConfigError("\(path): expected an object") }
        var result: [Trigger: Assignment] = [:]
        for (name, assignment) in object {
            let trigger: Trigger
            do { trigger = try Trigger(parsing: name) } catch { throw ConfigError("\(path): \(error)") }
            result[trigger] = try parseAssignment(assignment, path: "\(path).\(name)")
        }
        return result
    }

    private static let optionKeys: Set<String> = ["on", "hold", "repeat", "steps"]

    private static func parseAssignment(_ value: Any, path: String) throws -> Assignment {
        if let steps = value as? [Any] {
            return Assignment(steps: try steps.enumerated().map { try parseStep($1, path: "\(path)[\($0)]") })
        }
        guard let object = value as? [String: Any] else {
            return Assignment(steps: [try parseStep(value, path: path)])
        }

        var assignment = Assignment(steps: [])
        if let steps = object["steps"] {
            guard let steps = steps as? [Any] else { throw ConfigError("\(path).steps: expected an array") }
            assignment.steps = try steps.enumerated().map { try parseStep($1, path: "\(path).steps[\($0)]") }
            if let extra = object.keys.first(where: { !optionKeys.contains($0) }) {
                throw ConfigError("\(path): \"\(extra)\" cannot be combined with steps")
            }
        } else {
            assignment.steps = [try parseStep(object.filter { !optionKeys.contains($0.key) }, path: path)]
        }

        if let on = object["on"] {
            switch on as? String {
            case "press": assignment.onRelease = false
            case "release": assignment.onRelease = true
            default: throw ConfigError("\(path).on: expected \"press\" or \"release\"")
            }
        }
        if let hold = object["hold"] {
            guard let flag = hold as? Bool else { throw ConfigError("\(path).hold: expected true or false") }
            assignment.hold = flag
            if flag {
                guard assignment.steps.count == 1, case .tap = assignment.steps[0] else {
                    throw ConfigError("\(path).hold: only works with a single `keys` action")
                }
            }
        }
        if let interval = object["repeat"] {
            guard let ms = interval as? Int, ms > 0 else { throw ConfigError("\(path).repeat: expected milliseconds > 0") }
            assignment.repeatMs = ms
        }
        return assignment
    }

    private static func parseStep(_ value: Any, path: String) throws -> Step {
        do {
            if let chord = value as? String { return .tap(try Chord(chord)) }
            guard let object = value as? [String: Any] else { throw ConfigError("expected a key chord string or an action object") }
            let actions = object.filter { $0.key != "count" }
            guard actions.count == 1, let (name, argument) = actions.first else {
                throw ConfigError("expected exactly one action (keys, text, shell, app, open, click, media, light, macro, profile, delay, down, up), got: \(object.keys.sorted().joined(separator: ", "))")
            }
            func string() throws -> String {
                guard let text = argument as? String else { throw ConfigError("\(name): expected a string") }
                return text
            }
            switch name {
            case "keys": return .tap(try Chord(try string()))
            case "down": return .down(try Chord(try string()))
            case "up": return .up(try Chord(try string()))
            case "text": return .text(try string())
            case "shell": return .shell(try string())
            case "app": return .app(try string())
            case "open": return .open(try string())
            case "macro": return .macro(try string())
            case "profile": return .profile(try string())
            case "delay":
                guard let ms = argument as? Int, ms >= 0 else { throw ConfigError("delay: expected milliseconds") }
                return .delay(ms)
            case "media":
                guard let key = MediaKey(name: try string()) else {
                    throw ConfigError("media: expected one of \(MediaKey.allCases.map(\.name).joined(separator: ", "))")
                }
                return .media(key)
            case "light":
                let words = try string()
                _ = try LightCommand(words: words.split(separator: " ").map(String.init))
                return .light(words)
            case "click":
                guard let button = MouseButton(rawValue: try string().lowercased()) else { throw ConfigError("click: expected left, right or middle") }
                return .click(button, max((object["count"] as? Int) ?? 1, 1))
            default:
                throw ConfigError("unknown action \"\(name)\"")
            }
        } catch let error as ConfigError {
            throw ConfigError("\(path): \(error.description)")
        }
    }

    /// `"05ac:024f"`, or `{ id: "05ac:024f", name: "Keychron K2", layout: "75%" }`.
    private static func parseKeyboard(_ value: Any, path: String) throws -> OtherKeyboard {
        let object = value as? [String: Any] ?? (value as? String).map { ["id": $0] }
        guard let object else { throw ConfigError("\(path): expected { id: \"vendor:product\" }") }
        guard let id = (object["id"] as? String).flatMap(DeviceID.init) else {
            throw ConfigError("\(path).id: expected the keyboard's USB ids in hex, like \"05ac:024f\" (`rzmacro status` lists them)")
        }
        guard id.vendor != DeviceManager.razerVendorID else { throw ConfigError("\(path): Razer devices are looked after already") }
        var keyboard = OtherKeyboard(id: id, name: object["name"] as? String ?? "Keyboard \(id)")
        if let layout = object["layout"] {
            guard let shape = (layout as? String).flatMap(KeyboardShape.init(rawValue:)) else {
                throw ConfigError("\(path).layout: expected one of \(KeyboardShape.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            keyboard.shape = shape
        }
        if let extra = object.keys.first(where: { !["id", "name", "layout"].contains($0) }) {
            throw ConfigError("\(path): unknown option \"\(extra)\" (expected id, name, layout)")
        }
        return keyboard
    }

    // MARK: Writing

    var jsonObject: [String: Any] {
        func bindingsObject(_ bindings: [Trigger: Assignment]) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.displayName, $0.value.jsonValue) })
        }
        var object: [String: Any] = [
            "devices": Dictionary(uniqueKeysWithValues: DeviceKind.allCases.map { ($0.rawValue, ["driverMode": driverMode[$0] ?? false]) }),
            "bindings": bindingsObject(bindings),
        ]
        if !keyboards.isEmpty {
            object["keyboards"] = keyboards.map { ["id": $0.id.description, "name": $0.name, "layout": $0.shape.rawValue] }
        }
        if !profiles.isEmpty {
            object["profiles"] = profiles.map { profile -> [String: Any] in
                var object: [String: Any] = ["name": profile.name, "bindings": bindingsObject(profile.bindings)]
                if profile.partial {
                    object["partial"] = true
                } else if profile.basedOn != Profile.defaultName {
                    object["basedOn"] = profile.basedOn ?? NSNull()
                }
                if !profile.apps.isEmpty { object["apps"] = profile.apps }
                if profile.whileRunning { object["whileRunning"] = true }
                if !profile.heroes.isEmpty { object["heroes"] = profile.heroes }
                if let dota = profile.dota { object["dota"] = dota.rawValue }
                return object
            }
        }
        if !autoSwitch { object["autoSwitch"] = false }
        if profileNotes != .notApps { object["profileNotes"] = profileNotes.rawValue }
        if !macros.isEmpty {
            object["macros"] = macros.mapValues { macro -> Any in
                let steps = macro.steps.map(\.jsonValue)
                return macro.keyDelay.map { ["steps": steps, "keyDelay": $0] as [String: Any] } ?? steps
            }
        }
        if keyDelay != 0 { object["keyDelay"] = keyDelay }
        if let lighting { object["lighting"] = lighting.jsonObject }
        return object
    }

    func save(to url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: jsonObject, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let header = "// rzmacro configuration. Edit it in the RZMacro app, or here (changes are picked up on save).\n"
        try (header + String(decoding: data, as: UTF8.self) + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

extension Step {
    var jsonValue: Any {
        switch self {
        case .tap(let chord): return chord.description
        case .down(let chord): return ["down": chord.description]
        case .up(let chord): return ["up": chord.description]
        case .text(let text): return ["text": text]
        case .delay(let ms): return ["delay": ms]
        case .shell(let command): return ["shell": command]
        case .app(let name): return ["app": name]
        case .open(let target): return ["open": target]
        case .click(let button, let count):
            var object: [String: Any] = ["click": button.rawValue]
            if count > 1 { object["count"] = count }
            return object
        case .media(let key): return ["media": key.name]
        case .light(let words): return ["light": words]
        case .macro(let name): return ["macro": name]
        case .profile(let name): return ["profile": name]
        }
    }
}

extension Assignment {
    var jsonValue: Any {
        guard onRelease || hold || repeatMs != nil else {
            return steps.count == 1 ? steps[0].jsonValue : steps.map(\.jsonValue)
        }
        var object: [String: Any]
        if steps.count == 1 {
            if case .tap(let chord) = steps[0] { object = ["keys": chord.description] } else { object = (steps[0].jsonValue as? [String: Any]) ?? [:] }
        } else {
            object = ["steps": steps.map(\.jsonValue)]
        }
        if onRelease { object["on"] = "release" }
        if hold { object["hold"] = true }
        if let repeatMs { object["repeat"] = repeatMs }
        return object
    }
}
