import AppKit
import Network

/// Which Dota 2 hero is being played, so a profile can follow it.
///
/// Dota tells whoever asks: its Game State Integration posts the state of the match as JSON to
/// the addresses listed in small settings files in its `cfg/gamestate_integration` folder. This
/// adds one of those files, pointing at a port on this Mac only, and listens there. It is
/// Valve's own interface for overlays and stream tools — nothing is read out of the game's
/// memory. The game only does this when started with `-gamestateintegration`.
///
/// Nothing is listened for until the user sets it up; the settings file is the switch.
final class DotaWatcher {
    static let bundleID = "com.valvesoftware.dota2"
    static let launchOption = "-gamestateintegration"

    private static let steamAppID = "570"
    private static let fileName = "gamestate_integration_rzmacro.cfg"
    private static let firstPort: UInt16 = 35570

    struct Status: Equatable {
        /// The game was found on this Mac.
        var found = false
        /// Our settings file is in its folder.
        var installed = false
        var port: UInt16?
        /// Why listening failed, if it did.
        var error: String?
        var running = false
        /// The game has reported in the last little while.
        var receiving = false
        var hero: String?
    }

    /// The hero being played, by internal name without the "npc_dota_hero_" prefix.
    private(set) var hero: String?
    /// Called on the main queue when the hero changes.
    var onChange: (() -> Void)?

    private var listener: NWListener?
    private var port: UInt16?
    private var token: String?
    private var error: String?
    private var lastUpdate: Date?

    // MARK: Finding the game

    private static let steam = Paths.home.appendingPathComponent("Library/Application Support/Steam")

    private static var foundDirectory: URL?

    /// `…/dota 2 beta/game/dota`, in whichever Steam library holds it.
    static func gameDirectory() -> URL? {
        if let found = foundDirectory, FileManager.default.fileExists(atPath: found.path) { return found }
        foundDirectory = findGameDirectory()
        return foundDirectory
    }

    private static func findGameDirectory() -> URL? {
        var libraries = [steam]
        if let text = try? String(contentsOf: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8) {
            for case let library as [String: Any] in (VDF.parse(text)["libraryfolders"] as? [String: Any] ?? [:]).values {
                if let path = library["path"] as? String { libraries.append(URL(fileURLWithPath: path)) }
            }
        }
        var candidates = libraries.map { $0.appendingPathComponent("steamapps/common/dota 2 beta/game/dota") }
        // The app itself sits at game/bin/osx64/dota2.app.
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            candidates.append(app.appendingPathComponent("../../../dota").standardizedFileURL)
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("cfg").path) }
    }

    private static var settingsFile: URL? {
        gameDirectory()?.appendingPathComponent("cfg/gamestate_integration/\(fileName)")
    }

    private static var runningGame: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static var isRunning: Bool { runningGame != nil }

    // MARK: Setting up

    /// The port and token in the installed settings file.
    private static func installed() -> (port: UInt16, token: String?)? {
        guard let file = settingsFile, let text = try? String(contentsOf: file, encoding: .utf8),
              let settings = VDF.parse(text).values.first as? [String: Any],
              let port = (settings["uri"] as? String).flatMap({ URL(string: $0)?.port }).flatMap({ UInt16(exactly: $0) })
        else { return nil }
        return (port, (settings["auth"] as? [String: Any])?["token"] as? String)
    }

    private static func isFree(_ port: UInt16) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0 }
        }
    }

    /// Adds the settings file to the game and starts listening. Dota reads the file when it
    /// starts, so a running game has to be restarted.
    func install() throws {
        guard let file = Self.settingsFile else { throw ConfigError("Dota 2 was not found in the Steam library on this Mac") }
        stop()
        guard let port = (Self.firstPort..<Self.firstPort + 20).first(where: Self.isFree) else {
            throw ConfigError("no free port to listen on near \(Self.firstPort)")
        }
        let token = UUID().uuidString
        // Fields as Valve documents them. Only the hero is asked for, once a second at most.
        let settings = """
        "RZMacro: tells RZMacro which hero is being played, so it can switch profile"
        {
            "uri"        "http://127.0.0.1:\(port)/"
            "timeout"    "5.0"
            "buffer"     "0.5"
            "throttle"   "1.0"
            "heartbeat"  "10.0"
            "auth"
            {
                "token"  "\(token)"
            }
            "data"
            {
                "provider"  "1"
                "hero"      "1"
            }
        }

        """
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try settings.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw ConfigError("could not write \(file.path): \(error.localizedDescription)")
        }
        log("dota: wrote \(file.path)")
        start()
    }

    /// Takes the settings file out of the game again and stops listening.
    func uninstall() {
        stop()
        if let file = Self.settingsFile, FileManager.default.fileExists(atPath: file.path) {
            try? FileManager.default.removeItem(at: file)
            log("dota: removed \(file.path)")
        }
    }

    // MARK: Listening

    /// Starts listening if the settings file is in place and nothing is listening yet.
    func start() {
        guard listener == nil, let installed = Self.installed(), let endpoint = NWEndpoint.Port(rawValue: installed.port) else { return }
        port = installed.port
        token = installed.token
        error = nil
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // This Mac only: the game runs here, and nobody else has any business asking.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: endpoint)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, case .failed(let failure) = state else { return }
                self.error = failure.localizedDescription
                log("dota: could not listen on port \(installed.port): \(failure)")
                self.listener?.cancel()
                self.listener = nil
                self.onChange?()
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: .main)
            self.listener = listener
            log("dota: listening for the game on 127.0.0.1:\(installed.port)")
        } catch {
            self.error = error.localizedDescription
            log("dota: could not listen on port \(installed.port): \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        port = nil
        error = nil
        lastUpdate = nil
        setHero(nil)
    }

    /// The game went away: whoever was being played no longer is.
    func gameQuit() {
        lastUpdate = nil
        setHero(nil)
    }

    private func setHero(_ new: String?) {
        guard new != hero else { return }
        hero = new
        log("dota: \(new.map { "playing \(DotaHeroes.title($0))" } ?? "no hero")")
        onChange?()
    }

    /// One request per connection: read it, answer 200 (anything else and the game treats the
    /// state as undelivered and sends it again), hang up.
    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { connection.cancel() }
        receive(on: connection, buffered: Data(), acknowledged: false)
    }

    private func receive(on connection: NWConnection, buffered: Data, acknowledged: Bool) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, finished, failure in
            guard let self else { return connection.cancel() }
            var buffer = buffered
            if let data { buffer.append(data) }
            var acknowledged = acknowledged
            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let header = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self).lowercased()
                let length = header.split(separator: "\r\n")
                    .first { $0.hasPrefix("content-length:") }
                    .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buffer[headerEnd.upperBound...]
                if body.count >= length {
                    if header.hasPrefix("post ") { self.received(Data(body.prefix(length))) }
                    let reply = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                    return connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in connection.cancel() })
                }
                // A client may hold the body back until it is told to go ahead.
                if !acknowledged, header.contains("expect: 100-continue") {
                    acknowledged = true
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                }
            }
            if finished || failure != nil || buffer.count > 1 << 20 { return connection.cancel() }
            self.receive(on: connection, buffered: buffer, acknowledged: acknowledged)
        }
    }

    private func received(_ body: Data) {
        guard let state = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else { return }
        // Anything on this Mac can post to the port; only the game knows the token.
        if let token, (state["auth"] as? [String: Any])?["token"] as? String != token { return }
        let wasReceiving = isReceiving
        lastUpdate = Date()
        // In the menus there is no hero at all; a spectator gets every player's, under other names.
        let name = (state["hero"] as? [String: Any])?["name"] as? String
        setHero(name.map(DotaHeroes.shortName))
        if !wasReceiving { onChange?() }
    }

    /// The game checks in every ten seconds even when nothing happens.
    private var isReceiving: Bool { lastUpdate.map { Date().timeIntervalSince($0) < 45 } ?? false }

    var status: Status {
        Status(
            found: Self.gameDirectory() != nil,
            installed: Self.settingsFile.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
            port: port, error: error, running: Self.isRunning, receiving: isReceiving, hero: hero)
    }

    // MARK: The launch option

    /// Whether the game is (or will be) started with the launch option it needs: true or false
    /// when it can be told, nil when not. A running game is asked directly; otherwise it is
    /// what Steam has stored.
    static func hasLaunchOption() -> Bool? {
        if let game = runningGame {
            let arguments = processArguments(game.processIdentifier)
            if !arguments.isEmpty { return arguments.contains(launchOption) }
        }
        let users = (try? FileManager.default.contentsOfDirectory(at: steam.appendingPathComponent("userdata"), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let configs = users.map { $0.appendingPathComponent("config/localconfig.vdf") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
            .sorted { modified($0) > modified($1) }
        guard let text = configs.first.flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) else { return nil }
        var node: Any? = VDF.parse(text)
        for key in ["userlocalconfigstore", "software", "valve", "steam", "apps", steamAppID] {
            node = (node as? [String: Any])?.first { $0.key.lowercased() == key }?.value
        }
        guard let app = node as? [String: Any] else { return nil }
        let options = app.first { $0.key.lowercased() == "launchoptions" }?.value as? String ?? ""
        return options.contains(launchOption)
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    /// The command line of one of the user's own processes.
    private static func processArguments(_ pid: pid_t) -> [String] {
        var name: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&name, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&name, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        // The argument count, the executable's path, padding, then the arguments, each ending in a zero byte.
        let count = buffer.withUnsafeBytes { $0.load(as: Int32.self) }
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < Int(count), index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            arguments.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments
    }
}

/// Valve's key-value text format, as much of it as it takes to look something up: quoted
/// keys, quoted values, blocks in braces.
enum VDF {
    static func parse(_ text: String) -> [String: Any] {
        var tokens: [String?] = []   // nil stands for a brace; which one is in `braces`
        var braces: [Bool] = []      // true opens
        let bytes = Array(text.utf8)
        var index = 0
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\""):
                var value: [UInt8] = []
                index += 1
                while index < bytes.count, bytes[index] != UInt8(ascii: "\"") {
                    if bytes[index] == UInt8(ascii: "\\"), index + 1 < bytes.count { index += 1 }
                    value.append(bytes[index])
                    index += 1
                }
                tokens.append(String(decoding: value, as: UTF8.self))
            case UInt8(ascii: "{"), UInt8(ascii: "}"):
                tokens.append(nil)
                braces.append(bytes[index] == UInt8(ascii: "{"))
            case UInt8(ascii: "/") where index + 1 < bytes.count && bytes[index + 1] == UInt8(ascii: "/"):
                while index < bytes.count, bytes[index] != UInt8(ascii: "\n") { index += 1 }
            default:
                break
            }
            index += 1
        }

        var position = 0, brace = 0
        func block() -> [String: Any] {
            var result: [String: Any] = [:]
            while position < tokens.count {
                guard let key = tokens[position] else {
                    // A closing brace ends this block; a stray opening one is skipped.
                    position += 1
                    brace += 1
                    if !braces[brace - 1] { return result }
                    continue
                }
                position += 1
                guard position < tokens.count else { break }
                if let value = tokens[position] {
                    position += 1
                    result[key] = value
                } else if braces[brace] {
                    position += 1
                    brace += 1
                    result[key] = block()
                }
            }
            return result
        }
        return block()
    }
}

/// Dota's heroes: what the game calls them internally, and what players call them.
enum DotaHeroes {
    static let prefix = "npc_dota_hero_"

    /// "npc_dota_hero_antimage" → "antimage".
    static func shortName(_ name: String) -> String {
        let lower = name.lowercased().trimmingCharacters(in: .whitespaces)
        return lower.hasPrefix(prefix) ? String(lower.dropFirst(prefix.count)) : lower.replacingOccurrences(of: " ", with: "_")
    }

    /// "antimage" → "Anti-Mage". A hero newer than this list gets its internal name, tidied up.
    static func title(_ name: String) -> String {
        if let known = titles[name] { return known }
        return name.split(separator: "_").map(String.init).map { ["of", "the"].contains($0) ? $0 : $0.capitalized }.joined(separator: " ")
    }

    /// The internal name for something a person might type: "Anti-Mage", "antimage", "am".
    static func name(matching text: String) -> String {
        let wanted = text.lowercased().filter { $0.isLetter || $0.isNumber }
        if let match = all.first(where: { $0.title.lowercased().filter { $0.isLetter || $0.isNumber } == wanted }) { return match.name }
        return shortName(text)
    }

    static let all: [(name: String, title: String)] = [
        ("abaddon", "Abaddon"), ("alchemist", "Alchemist"), ("ancient_apparition", "Ancient Apparition"),
        ("antimage", "Anti-Mage"), ("arc_warden", "Arc Warden"), ("axe", "Axe"), ("bane", "Bane"),
        ("batrider", "Batrider"), ("beastmaster", "Beastmaster"), ("bloodseeker", "Bloodseeker"),
        ("bounty_hunter", "Bounty Hunter"), ("brewmaster", "Brewmaster"), ("bristleback", "Bristleback"),
        ("broodmother", "Broodmother"), ("centaur", "Centaur Warrunner"), ("chaos_knight", "Chaos Knight"),
        ("chen", "Chen"), ("clinkz", "Clinkz"), ("rattletrap", "Clockwerk"), ("crystal_maiden", "Crystal Maiden"),
        ("dark_seer", "Dark Seer"), ("dark_willow", "Dark Willow"), ("dawnbreaker", "Dawnbreaker"),
        ("dazzle", "Dazzle"), ("death_prophet", "Death Prophet"), ("disruptor", "Disruptor"),
        ("doom_bringer", "Doom"), ("dragon_knight", "Dragon Knight"), ("drow_ranger", "Drow Ranger"),
        ("earth_spirit", "Earth Spirit"), ("earthshaker", "Earthshaker"), ("elder_titan", "Elder Titan"),
        ("ember_spirit", "Ember Spirit"), ("enchantress", "Enchantress"), ("enigma", "Enigma"),
        ("faceless_void", "Faceless Void"), ("grimstroke", "Grimstroke"), ("gyrocopter", "Gyrocopter"),
        ("hoodwink", "Hoodwink"), ("huskar", "Huskar"), ("invoker", "Invoker"), ("wisp", "Io"),
        ("jakiro", "Jakiro"), ("juggernaut", "Juggernaut"), ("keeper_of_the_light", "Keeper of the Light"),
        ("kez", "Kez"), ("kunkka", "Kunkka"), ("largo", "Largo"), ("legion_commander", "Legion Commander"),
        ("leshrac", "Leshrac"), ("lich", "Lich"), ("life_stealer", "Lifestealer"), ("lina", "Lina"),
        ("lion", "Lion"), ("lone_druid", "Lone Druid"), ("luna", "Luna"), ("lycan", "Lycan"),
        ("magnataur", "Magnus"), ("marci", "Marci"), ("mars", "Mars"), ("medusa", "Medusa"),
        ("meepo", "Meepo"), ("mirana", "Mirana"), ("monkey_king", "Monkey King"), ("morphling", "Morphling"),
        ("muerta", "Muerta"), ("naga_siren", "Naga Siren"), ("furion", "Nature's Prophet"),
        ("necrolyte", "Necrophos"), ("night_stalker", "Night Stalker"), ("nyx_assassin", "Nyx Assassin"),
        ("ogre_magi", "Ogre Magi"), ("omniknight", "Omniknight"), ("oracle", "Oracle"),
        ("obsidian_destroyer", "Outworld Destroyer"), ("pangolier", "Pangolier"),
        ("phantom_assassin", "Phantom Assassin"), ("phantom_lancer", "Phantom Lancer"), ("phoenix", "Phoenix"),
        ("primal_beast", "Primal Beast"), ("puck", "Puck"), ("pudge", "Pudge"), ("pugna", "Pugna"),
        ("queenofpain", "Queen of Pain"), ("razor", "Razor"), ("riki", "Riki"), ("ringmaster", "Ringmaster"),
        ("rubick", "Rubick"), ("sand_king", "Sand King"), ("shadow_demon", "Shadow Demon"),
        ("nevermore", "Shadow Fiend"), ("shadow_shaman", "Shadow Shaman"), ("silencer", "Silencer"),
        ("skywrath_mage", "Skywrath Mage"), ("slardar", "Slardar"), ("slark", "Slark"), ("snapfire", "Snapfire"),
        ("sniper", "Sniper"), ("spectre", "Spectre"), ("spirit_breaker", "Spirit Breaker"),
        ("storm_spirit", "Storm Spirit"), ("sven", "Sven"), ("techies", "Techies"),
        ("templar_assassin", "Templar Assassin"), ("terrorblade", "Terrorblade"), ("tidehunter", "Tidehunter"),
        ("shredder", "Timbersaw"), ("tinker", "Tinker"), ("tiny", "Tiny"), ("treant", "Treant Protector"),
        ("troll_warlord", "Troll Warlord"), ("tusk", "Tusk"), ("abyssal_underlord", "Underlord"),
        ("undying", "Undying"), ("ursa", "Ursa"), ("vengefulspirit", "Vengeful Spirit"),
        ("venomancer", "Venomancer"), ("viper", "Viper"), ("visage", "Visage"), ("void_spirit", "Void Spirit"),
        ("warlock", "Warlock"), ("weaver", "Weaver"), ("windrunner", "Windranger"),
        ("winter_wyvern", "Winter Wyvern"), ("witch_doctor", "Witch Doctor"), ("skeleton_king", "Wraith King"),
        ("zuus", "Zeus"),
    ]

    private static let titles = Dictionary(all.map { ($0.name, $0.title) }, uniquingKeysWith: { first, _ in first })
}
