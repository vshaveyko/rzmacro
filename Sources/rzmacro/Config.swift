import Foundation

/// Everything the user can configure. Lives in ~/.config/rzmacro/config.json5; the app reads
/// and writes it, and it stays hand-editable (JSON5 — comments survive until the app next saves).
struct Config: Equatable {
    /// Whether to switch each device kind into Razer driver mode while the driver runs.
    var driverMode: [DeviceKind: Bool] = [.keyboard: true, .mouse: true]
    var bindings: [Trigger: Assignment] = [:]
    /// Per-application overrides, keyed by bundle identifier.
    var apps: [String: [Trigger: Assignment]] = [:]
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
            case "bindings":
                config.bindings = try parseBindings(value, path: "bindings")
            case "apps":
                guard let apps = value as? [String: Any] else { throw ConfigError("apps: expected an object keyed by bundle id") }
                for (bundleID, bindings) in apps {
                    config.apps[bundleID] = try parseBindings(bindings, path: "apps.\(bundleID)")
                }
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
                throw ConfigError("unknown top-level key \"\(key)\" (expected devices, bindings, apps, macros, keyDelay, lighting)")
            }
        }
        return config
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
                throw ConfigError("expected exactly one action (keys, text, shell, app, open, click, media, light, macro, delay, down, up), got: \(object.keys.sorted().joined(separator: ", "))")
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

    // MARK: Writing

    var jsonObject: [String: Any] {
        func bindingsObject(_ bindings: [Trigger: Assignment]) -> [String: Any] {
            Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.displayName, $0.value.jsonValue) })
        }
        var object: [String: Any] = [
            "devices": Dictionary(uniqueKeysWithValues: DeviceKind.allCases.map { ($0.rawValue, ["driverMode": driverMode[$0] ?? false]) }),
            "bindings": bindingsObject(bindings),
        ]
        if !apps.isEmpty { object["apps"] = apps.mapValues(bindingsObject) }
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
