import Foundation

struct RGB: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    static let named: [String: RGB] = [
        "red": RGB(r: 255, g: 0, b: 0), "green": RGB(r: 0, g: 255, b: 0), "blue": RGB(r: 0, g: 0, b: 255),
        "white": RGB(r: 255, g: 255, b: 255), "yellow": RGB(r: 255, g: 255, b: 0), "cyan": RGB(r: 0, g: 255, b: 255),
        "magenta": RGB(r: 255, g: 0, b: 255), "orange": RGB(r: 255, g: 96, b: 0), "purple": RGB(r: 128, g: 0, b: 255),
        "pink": RGB(r: 255, g: 40, b: 120),
    ]

    init(r: UInt8, g: UInt8, b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    /// "#ff8800", "ff8800", "#f80" or a colour name.
    init(parsing text: String) throws {
        let lower = text.lowercased()
        if let named = Self.named[lower] { self = named; return }
        var digits = lower.hasPrefix("#") ? String(lower.dropFirst()) : lower
        if digits.count == 3 { digits = digits.map { "\($0)\($0)" }.joined() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else {
            throw ConfigError("\"\(text)\" is not a colour (use #rrggbb or one of \(Self.named.keys.sorted().joined(separator: ", ")))")
        }
        self.init(r: UInt8(value >> 16), g: UInt8((value >> 8) & 0xff), b: UInt8(value & 0xff))
    }

    /// Fully saturated colour for a hue in 0..<1.
    static func hue(_ hue: Double) -> RGB {
        let h = (hue - hue.rounded(.down)) * 6
        let x = UInt8((1 - abs(h.truncatingRemainder(dividingBy: 2) - 1)) * 255)
        switch Int(h) {
        case 0: return RGB(r: 255, g: x, b: 0)
        case 1: return RGB(r: x, g: 255, b: 0)
        case 2: return RGB(r: 0, g: 255, b: x)
        case 3: return RGB(r: 0, g: x, b: 255)
        case 4: return RGB(r: x, g: 0, b: 255)
        default: return RGB(r: 255, g: 0, b: x)
        }
    }

    func scaled(_ factor: Double) -> RGB {
        let f = min(max(factor, 0), 1)
        return RGB(r: UInt8(Double(r) * f), g: UInt8(Double(g) * f), b: UInt8(Double(b) * f))
    }

    var hex: String { String(format: "#%02x%02x%02x", r, g, b) }
}

enum LightEffect: Equatable {
    case off
    case solid(RGB)
    /// Fades each colour in and out in turn; `period` is one fade in and out.
    case breathing([RGB], period: Double)
    /// Every LED cycles through the hues together.
    case spectrum(period: Double)
    /// A rainbow travelling across the keyboard and on into the mouse.
    case wave(period: Double, reverse: Bool)

    var isAnimated: Bool {
        switch self {
        case .off, .solid: return false
        default: return true
        }
    }

    /// Colour of an LED at horizontal position `x` (0...1 across all devices) at `time` seconds.
    func color(x: Double, time: Double) -> RGB {
        switch self {
        case .off:
            return RGB(r: 0, g: 0, b: 0)
        case .solid(let color):
            return color
        case .breathing(let colors, let period):
            let cycle = time / period
            let color = colors[Int(cycle) % colors.count]
            return color.scaled((1 - cos(2 * .pi * cycle)) / 2)
        case .spectrum(let period):
            return .hue(time / period)
        case .wave(let period, let reverse):
            return .hue(reverse ? x + time / period : x - time / period)
        }
    }
}

struct LightSpec: Equatable, CustomStringConvertible {
    var effect: LightEffect
    /// 0...1, applied in software so it is identical on every device.
    var brightness: Double = 1
    var fps: Double = 24

    var description: String {
        let name: String
        switch effect {
        case .off: name = "off"
        case .solid(let color): name = "static \(color.hex)"
        case .breathing(let colors, let period): name = "breathing \(colors.map(\.hex).joined(separator: " ")) period=\(period)"
        case .spectrum(let period): name = "spectrum period=\(period)"
        case .wave(let period, let reverse): name = "wave period=\(period)\(reverse ? " reverse" : "")"
        }
        return "\(name) brightness=\(Int((brightness * 100).rounded()))"
    }

    init(effect name: String, colors: [RGB], period: Double?, reverse: Bool, brightness: Double?, fps: Double?) throws {
        if let period, period < 0.2 { throw ConfigError("period must be at least 0.2 seconds") }
        switch name.lowercased() {
        case "off", "none":
            effect = .off
        case "static", "solid":
            guard let color = colors.first else { throw ConfigError("static needs a colour") }
            effect = .solid(color)
        case "breathing", "breath", "breathe":
            guard !colors.isEmpty else { throw ConfigError("breathing needs at least one colour") }
            effect = .breathing(colors, period: period ?? 4)
        case "spectrum":
            effect = .spectrum(period: period ?? 12)
        case "wave":
            effect = .wave(period: period ?? 6, reverse: reverse)
        default:
            throw ConfigError("unknown effect \"\(name)\" (off, static, breathing, spectrum, wave)")
        }
        if let brightness {
            guard (0...100).contains(brightness) else { throw ConfigError("brightness must be 0…100") }
            self.brightness = brightness / 100
        }
        if let fps {
            guard (1...60).contains(fps) else { throw ConfigError("fps must be 1…60") }
            self.fps = fps
        }
    }

    /// `lighting: { effect: "wave", period: 6, brightness: 80 }`
    init(config: [String: Any]) throws {
        let known: Set<String> = ["effect", "color", "colors", "period", "reverse", "brightness", "fps"]
        if let unknown = config.keys.first(where: { !known.contains($0) }) {
            throw ConfigError("unknown option \"\(unknown)\" (expected \(known.sorted().joined(separator: ", ")))")
        }
        guard let name = config["effect"] as? String else { throw ConfigError("effect: expected off, static, breathing, spectrum or wave") }
        var colors: [RGB] = []
        if let color = config["color"] as? String { colors.append(try RGB(parsing: color)) }
        if let list = config["colors"] as? [String] { colors += try list.map { try RGB(parsing: $0) } }
        try self.init(
            effect: name, colors: colors,
            period: (config["period"] as? NSNumber)?.doubleValue,
            reverse: (config["reverse"] as? Bool) ?? false,
            brightness: (config["brightness"] as? NSNumber)?.doubleValue,
            fps: (config["fps"] as? NSNumber)?.doubleValue)
    }

    /// `static ff8800`, `wave period=4 reverse brightness=60`
    init(words: [String]) throws {
        guard let name = words.first else { throw ConfigError("expected an effect: off, static, breathing, spectrum, wave") }
        var colors: [RGB] = []
        var options: [String: Double] = [:]
        var reverse = false
        for word in words.dropFirst() {
            let pair = word.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                guard ["period", "brightness", "fps"].contains(pair[0]), let value = Double(pair[1]) else {
                    throw ConfigError("bad option \"\(word)\" (period=<seconds>, brightness=<0-100>, fps=<1-60>)")
                }
                options[pair[0]] = value
            } else if word == "reverse" {
                reverse = true
            } else {
                colors.append(try RGB(parsing: word))
            }
        }
        try self.init(effect: name, colors: colors, period: options["period"], reverse: reverse, brightness: options["brightness"], fps: options["fps"])
    }
}

extension LightSpec {
    /// The effect without its parameters, for pickers.
    enum Kind: String, CaseIterable {
        case off, solid = "static", breathing, spectrum, wave

        var title: String {
            switch self {
            case .off: return "Off"
            case .solid: return "Static"
            case .breathing: return "Breathing"
            case .spectrum: return "Spectrum"
            case .wave: return "Wave"
            }
        }
    }

    var kind: Kind {
        switch effect {
        case .off: return .off
        case .solid: return .solid
        case .breathing: return .breathing
        case .spectrum: return .spectrum
        case .wave: return .wave
        }
    }

    var colors: [RGB] {
        switch effect {
        case .solid(let color): return [color]
        case .breathing(let colors, _): return colors
        default: return []
        }
    }

    var period: Double? {
        switch effect {
        case .breathing(_, let period), .spectrum(let period), .wave(let period, _): return period
        default: return nil
        }
    }

    var reverse: Bool {
        if case .wave(_, let reverse) = effect { return reverse }
        return false
    }

    /// Builds a spec from loose parts, filling in whatever the effect needs (the app's editor).
    init(kind: Kind, colors: [RGB], period: Double?, reverse: Bool, brightness: Double, fps: Double = 24) {
        let colors = colors.isEmpty ? [RGB(r: 0, g: 255, b: 102)] : colors
        switch kind {
        case .off: effect = .off
        case .solid: effect = .solid(colors[0])
        case .breathing: effect = .breathing(colors, period: max(period ?? 4, 0.2))
        case .spectrum: effect = .spectrum(period: max(period ?? 12, 0.2))
        case .wave: effect = .wave(period: max(period ?? 6, 0.2), reverse: reverse)
        }
        self.brightness = min(max(brightness, 0), 1)
        self.fps = min(max(fps, 1), 60)
    }

    var jsonObject: [String: Any] {
        var object: [String: Any] = ["effect": kind.rawValue, "brightness": Int((brightness * 100).rounded())]
        if colors.count == 1 { object["color"] = colors[0].hex }
        if colors.count > 1 { object["colors"] = colors.map(\.hex) }
        if let period { object["period"] = period }
        if reverse { object["reverse"] = true }
        if fps != 24 { object["fps"] = fps }
        return object
    }
}

/// What `rzmacro light …` and the `light` macro action can ask for.
enum LightCommand: Equatable {
    case set(LightSpec)
    /// Absolute brightness, 0...1.
    case brightness(Double)
    /// Relative brightness change, -1...1.
    case adjust(Double)

    /// `static red`, `brightness 40`, `brightness +10`
    init(words: [String]) throws {
        if words.first == "brightness" {
            guard words.count == 2, let value = Double(words[1]), (-100...100).contains(value) else {
                throw ConfigError("usage: brightness <0-100> or brightness <+N|-N>")
            }
            self = words[1].hasPrefix("+") || words[1].hasPrefix("-") ? .adjust(value / 100) : .brightness(value / 100)
        } else {
            self = .set(try LightSpec(words: words))
        }
    }
}

/// How one device model's LEDs are addressed and where they sit relative to the others.
struct LightLayout {
    enum Transport {
        /// Per-LED "custom frames": `rows` matrix rows of `positions.count` columns each. Some
        /// devices insist on a fixed data size for frame packets; nil means "as long as the row".
        case frames(rows: Int, packetSize: UInt8?)
        /// One colour per zone, set with the plain "static" effect command — for devices whose
        /// matrix size isn't known.
        case uniform
    }

    let transport: Transport
    /// LED zones: their hardware brightness has to be up for anything to show, and with
    /// `.uniform` each one is coloured separately.
    let zones: [UInt8]
    /// Horizontal position, in a space shared by all devices (keyboard on the left 80%, mouse
    /// to its right), of each matrix column (`.frames`) or each zone (`.uniform`).
    let positions: [Double]
}

/// Renders the active effect for every device from one clock and streams the result as custom
/// frames. The devices' built-in effects run on their own timers and drift apart; this cannot.
final class LightingController {
    struct Target {
        let name: String
        let control: RazerControl
        let layout: LightLayout
    }

    private let queue = DispatchQueue(label: "rzmacro.lighting", qos: .utility)
    /// Time zero of every effect; shared so the app's preview is in phase with the LEDs.
    static let epoch = Date()
    private var timer: DispatchSourceTimer?
    private var targets: [Target] = []
    private var spec: LightSpec?
    /// Last row sent per device, to skip frames that would change nothing.
    private var lastRows: [ObjectIdentifier: [UInt8]] = [:]
    /// Devices whose first frame was sent with replies read and came back accepted.
    private var prepared = Set<ObjectIdentifier>()
    /// For `.uniform` devices: indices of the zones that turned out to exist.
    private var uniformZones: [ObjectIdentifier: [Int]] = [:]

    private let statusLock = NSLock()
    private var statusText = "not managed"

    var status: String {
        statusLock.lock()
        defer { statusLock.unlock() }
        return statusText
    }

    func update(spec: LightSpec?) {
        queue.async {
            guard spec != self.spec else { return }
            self.spec = spec
            self.lastRows.removeAll()
            self.restartTimer()
            self.render()
        }
    }

    func update(targets: [Target]) {
        queue.async {
            self.targets = targets
            let alive = Set(targets.map { ObjectIdentifier($0.control) })
            self.prepared.formIntersection(alive)
            self.lastRows = self.lastRows.filter { alive.contains($0.key) }
            self.render()
        }
    }

    /// Forget what the devices are showing (they may have been power-cycled) and send it again.
    func invalidate() {
        queue.async {
            self.lastRows.removeAll()
            self.prepared.removeAll()
            self.render()
        }
    }

    /// Cheap when nothing changed; retries devices whose last frame failed.
    func refresh() {
        queue.async { self.render() }
    }

    private func restartTimer() {
        timer?.cancel()
        timer = nil
        guard let spec, spec.effect.isAnimated else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1 / spec.fps, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.render() }
        timer.resume()
        self.timer = timer
    }

    private func render() {
        guard let spec else {
            setStatus("not managed")
            return
        }
        let time = Date().timeIntervalSince(Self.epoch)
        var failures: [String] = []
        for target in targets {
            let id = ObjectIdentifier(target.control)
            let row = target.layout.positions.flatMap { x -> [UInt8] in
                let color = spec.effect.color(x: x, time: time).scaled(spec.brightness)
                return [color.r, color.g, color.b]
            }
            if lastRows[id] == row { continue }
            do {
                try send(row, to: target, checked: !prepared.contains(id))
                if prepared.insert(id).inserted { log("lighting: \(target.name) is taking colours") }
                lastRows[id] = row
            } catch {
                if prepared.remove(id) != nil || lastRows[id] == nil { log("lighting: \(target.name): \(error)") }
                lastRows[id] = []
                failures.append(target.name)
            }
        }
        let names = targets.map(\.name).joined(separator: " + ")
        setStatus("\(spec) on \(names.isEmpty ? "no devices" : names)" + (failures.isEmpty ? "" : "  FAILING: \(failures.joined(separator: ", "))"))
    }

    /// Puts one set of colours (`row`: RGB per position) on a device's LEDs.
    /// `checked` reads the device's answers (slower) so a rejected command is noticed.
    private func send(_ row: [UInt8], to target: Target, checked: Bool) throws {
        let layout = target.layout
        func command(_ id: UInt8, _ size: UInt8, _ args: [UInt8]) throws {
            if checked {
                try target.control.send(class: 0x0f, id: id, size: size, args: args)
            } else {
                try target.control.post(class: 0x0f, id: id, size: size, args: args)
            }
        }

        switch layout.transport {
        case .frames(let rows, let packetSize):
            if checked {
                for zone in layout.zones where try target.control.brightness(led: zone) != 0xff {
                    try target.control.setBrightness(0xff, led: zone)
                }
            }
            // Every matrix row, then the command that shows the frame.
            for index in 0..<rows {
                try command(0x03, packetSize ?? UInt8(row.count + 5), [0x00, 0x00, UInt8(index), 0x00, UInt8(layout.positions.count - 1)] + row)
            }
            try command(0x02, 0x0c, [0x00, 0x00, 0x08])

        case .uniform:
            // Zones are a guess for an unknown device: find out once which ones it has.
            let id = ObjectIdentifier(target.control)
            if checked {
                uniformZones[id] = layout.zones.indices.filter { index in
                    (try? target.control.setBrightness(0xff, led: layout.zones[index])) != nil
                }
                if uniformZones[id]?.isEmpty != false { throw ConfigError("none of the usual lighting zones answered") }
            }
            for index in uniformZones[id] ?? [] {
                // "Static" effect, not stored: [storage, zone, effect, -, -, colour count, r, g, b]
                try command(0x02, 0x09, [0x00, layout.zones[index], 0x01, 0x00, 0x00, 0x01] + row[(index * 3)..<(index * 3 + 3)])
            }
        }
    }

    private func setStatus(_ text: String) {
        statusLock.lock()
        statusText = text
        statusLock.unlock()
    }
}
