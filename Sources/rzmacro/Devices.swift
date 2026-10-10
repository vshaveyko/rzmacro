import Foundation
import IOKit
import IOKit.hid

enum DeviceKind: String, CaseIterable {
    case keyboard, mouse

    init?(configName: String) {
        switch configName.lowercased() {
        case "keyboard", "kbd", "blackwidow": self = .keyboard
        case "mouse", "naga": self = .mouse
        default: return nil
        }
    }
}

/// Where a button press was observed.
enum KeySource: Hashable, CustomStringConvertible {
    /// Vendor code on report ID 4 — how Razer devices report keys they don't handle themselves.
    case raw(UInt8)
    /// Keyboard-page usage: a key typed by a mouse button, or an ordinary key of a keyboard.
    case key(UInt8)
    /// Bit in the mouse button byte: 0 left, 1 right, 2 middle (the wheel), 3 back, 4 forward.
    case button(Int)
    /// A notch of the scroll wheel.
    case wheel(up: Bool)

    var description: String {
        switch self {
        case .raw(let code): return String(format: "raw:%02x", code)
        case .key(let usage): return String(format: "key:%02x", usage)
        case .button(let bit): return "btn:\(bit)"
        case .wheel(let up): return up ? "wheel:up" : "wheel:down"
        }
    }

    init?(parsing text: String) {
        let parts = text.lowercased().split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        switch parts[0] {
        case "raw": guard let v = UInt8(parts[1], radix: 16) else { return nil }; self = .raw(v)
        case "key": guard let v = UInt8(parts[1], radix: 16) else { return nil }; self = .key(v)
        case "btn": guard let v = Int(parts[1]), (0..<8).contains(v) else { return nil }; self = .button(v)
        case "wheel": guard ["up", "down"].contains(parts[1]) else { return nil }; self = .wheel(up: parts[1] == "up")
        default: return nil
        }
    }
}

/// A physical button on a device kind; what bindings are keyed by.
struct Trigger: Hashable, CustomStringConvertible {
    let kind: DeviceKind
    let source: KeySource

    var description: String { "\(kind.rawValue).\(source)" }

    /// Friendly name when there is one: "keyboard.M1", "keyboard.capslock".
    var displayName: String {
        if kind == .keyboard, case .key(let usage) = source {
            return KeyboardKeys.byUsage[usage].map { "keyboard.\($0.name)" } ?? description
        }
        if let name = KeyNames.table(for: kind).first(where: { $0.1 == source })?.0 { return "\(kind.rawValue).\(name)" }
        return description
    }

    init(kind: DeviceKind, source: KeySource) {
        self.kind = kind
        self.source = source
    }

    /// "keyboard.M1", "keyboard.capslock", "mouse.7", "mouse.raw:20"
    init(parsing text: String) throws {
        guard let dot = text.firstIndex(of: "."), let kind = DeviceKind(configName: String(text[..<dot])) else {
            throw ConfigError("\"\(text)\": expected \"keyboard.<key>\" or \"mouse.<button>\"")
        }
        let name = String(text[text.index(after: dot)...])
        if let source = KeySource(parsing: name) {
            self.init(kind: kind, source: source)
        } else if let source = KeyNames.table(for: kind).first(where: { $0.0.lowercased() == name.lowercased() })?.1 {
            self.init(kind: kind, source: source)
        } else if kind == .keyboard, let usage = KeyboardKeys.usage(named: name) {
            self.init(kind: kind, source: .key(usage))
        } else {
            let known = KeyNames.table(for: kind).map(\.0).joined(separator: ", ") + (kind == .keyboard ? ", any key by name (capslock, a, left-cmd…)" : "")
            throw ConfigError("\"\(text)\": unknown \(kind.rawValue) key \"\(name)\" (known: \(known), or raw:XX / key:XX / btn:N / wheel:up|down)")
        }
    }
}

enum KeyNames {
    static let keyboard: [(String, KeySource)] = [
        ("M1", .raw(0x20)), ("M2", .raw(0x21)), ("M3", .raw(0x22)),
        ("M4", .raw(0x23)), ("M5", .raw(0x24)), ("M6", .raw(0x25)),
        // The volume roller, one event per notch.
        ("roller-up", .raw(0x51)), ("roller-down", .raw(0x50)),
    ]

    static let mouse: [(String, KeySource)] = [
        ("1", .key(0x1e)), ("2", .key(0x1f)), ("3", .key(0x20)), ("4", .key(0x21)),
        ("5", .key(0x22)), ("6", .key(0x23)), ("7", .key(0x24)), ("8", .key(0x25)),
        ("9", .key(0x26)), ("10", .key(0x27)), ("11", .key(0x2d)), ("12", .key(0x2e)),
        ("right-click", .button(1)), ("wheel-click", .button(2)), ("back", .button(3)), ("forward", .button(4)),
        ("wheel-up", .wheel(up: true)), ("wheel-down", .wheel(up: false)),
    ]

    static func table(for kind: DeviceKind) -> [(String, KeySource)] {
        kind == .keyboard ? keyboard : mouse
    }
}

/// One USB HID interface of a Razer device.
final class HIDInterface {
    let device: IOHIDDevice
    /// USB bInterfaceNumber, -1 if it couldn't be read.
    let number: Int
    /// USB bInterfaceProtocol: 1 keyboard, 2 mouse.
    let usbProtocol: Int
    let usagePage: Int
    let usage: Int
    let maxInput: Int
    let maxFeature: Int
    var openResult: IOReturn = kIOReturnNotOpen
    /// Opened exclusively: macOS itself no longer receives this interface's reports.
    private(set) var isSeized = false
    private var watchesKeys = false
    weak var owner: RazerDevice?

    /// Keyboard usages currently reported down on this interface.
    var keysDown = Set<UInt8>()
    /// Keys a mouse keeps reporting down with no button holding them, and how many copies of
    /// each (see `KeySlots`).
    var stuckKeys: [UInt8: Int] = [:]
    var lastSniffed: [UInt8] = []

    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize: Int
    /// HID elements looked up so far, by usage page and usage.
    private var elements: [UInt32: IOHIDElement?] = [:]
    /// Every key or button element of the interface, once they have been asked for.
    private var inputs: [IOHIDElement]?

    var isKeyboard: Bool { usagePage == 1 && usage == 6 }
    var isMouse: Bool { usagePage == 1 && usage == 2 }
    var isControl: Bool { maxFeature == RazerControl.reportLength }

    var role: String {
        var parts: [String] = []
        if isKeyboard { parts.append(maxInput > 8 ? "keyboard+vendor" : "keyboard") }
        else if isMouse { parts.append("mouse") }
        else { parts.append(String(format: "usage %02x/%02x", usagePage, usage)) }
        if isControl { parts.append("control") }
        return parts.joined(separator: "+")
    }

    init(device: IOHIDDevice) {
        self.device = device
        func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0 }
        usagePage = int(kIOHIDPrimaryUsagePageKey)
        usage = int(kIOHIDPrimaryUsageKey)
        maxInput = int(kIOHIDMaxInputReportSizeKey)
        maxFeature = int(kIOHIDMaxFeatureReportSizeKey)

        func usb(_ key: String) -> Int? {
            let service = IOHIDDeviceGetService(device)
            guard service != MACH_PORT_NULL else { return nil }
            let options = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            return (IORegistryEntrySearchCFProperty(service, kIOServicePlane, key as CFString, kCFAllocatorDefault, options) as? NSNumber)?.intValue
        }
        number = usb("bInterfaceNumber") ?? -1
        usbProtocol = usb("bInterfaceProtocol") ?? 0

        bufferSize = max(maxInput, 64)
        buffer = .allocate(capacity: bufferSize)
        buffer.initialize(repeating: 0, count: bufferSize)
    }

    func open(seize: Bool, reportHandler: @escaping IOHIDReportCallback) {
        if seize {
            openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeSeizeDevice))
            isSeized = openResult == kIOReturnSuccess
        }
        if !isSeized { openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone)) }
        guard openResult == kIOReturnSuccess, maxInput > 0 else { return }
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, reportHandler, Unmanaged.passUnretained(self).toOpaque())
        IOHIDDeviceScheduleWithRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    /// Asks to be told about every key on this interface going down or up. The values come from
    /// the system's own reading of the report descriptor, so it makes no difference whether
    /// the keyboard reports six keys at a time or all of them.
    func watchKeys(_ handler: @escaping IOHIDValueCallback) {
        guard openResult == kIOReturnSuccess, isKeyboard, maxInput > 0 else { return }
        IOHIDDeviceSetInputValueMatching(device, [kIOHIDElementUsagePageKey: kHIDPage_KeyboardOrKeypad] as CFDictionary)
        IOHIDDeviceRegisterInputValueCallback(device, handler, Unmanaged.passUnretained(self).toOpaque())
        watchesKeys = true
    }

    func close() {
        guard openResult == kIOReturnSuccess else { return }
        if watchesKeys { IOHIDDeviceRegisterInputValueCallback(device, nil, nil) }
        if maxInput > 0 {
            IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, nil, nil)
            IOHIDDeviceUnscheduleFromRunLoop(device, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        openResult = kIOReturnNotOpen
    }

    deinit { buffer.deallocate() }

    /// Whether a key or button is down right now, asked of the kernel's element cache rather
    /// than taken from our report callbacks: an event tap can see the event before the callback
    /// for the same press has run.
    private func isDownNow(page: Int, usage: Int) -> Bool {
        guard openResult == kIOReturnSuccess else { return false }
        let id = UInt32(page) << 16 | UInt32(usage)
        if elements[id] == nil {
            let match = [kIOHIDElementUsagePageKey: page, kIOHIDElementUsageKey: usage] as CFDictionary
            elements[id] = .some((IOHIDDeviceCopyMatchingElements(device, match, 0) as? [IOHIDElement])?.first)
        }
        guard let element = elements[id] ?? nil else { return false }
        return isDown(element)
    }

    private func isDown(_ element: IOHIDElement) -> Bool {
        let value = UnsafeMutablePointer<Unmanaged<IOHIDValue>>.allocate(capacity: 1)
        defer { value.deallocate() }
        guard IOHIDDeviceGetValue(device, element, value) == kIOReturnSuccess else { return false }
        return IOHIDValueGetIntegerValue(value.pointee.takeUnretainedValue()) != 0
    }

    /// Every key (of a keyboard interface) or button (of a mouse one) that is down right now, by
    /// the kernel's element cache — which also knows what went down before we were listening.
    func usagesDownNow() -> Set<Int> {
        guard openResult == kIOReturnSuccess, isKeyboard || isMouse else { return [] }
        if inputs == nil {
            let page = isKeyboard ? kHIDPage_KeyboardOrKeypad : kHIDPage_Button
            let all = IOHIDDeviceCopyMatchingElements(device, [kIOHIDElementUsagePageKey: page] as CFDictionary, 0) as? [IOHIDElement] ?? []
            // Usages 1 to 3 of a keyboard are its ways of saying "too many keys", not keys.
            inputs = all.filter {
                [kIOHIDElementTypeInput_Button, kIOHIDElementTypeInput_Misc].contains(IOHIDElementGetType($0))
                    && ((isKeyboard ? 4 : 1)...0xe7).contains(Int(IOHIDElementGetUsage($0)))
            }
        }
        return Set((inputs ?? []).filter(isDown).map { Int(IOHIDElementGetUsage($0)) })
    }

    func isKeyDownNow(_ usage: UInt8) -> Bool {
        // A stuck key is down as far as the kernel knows; only our own count can tell a press of it.
        keysDown.contains(usage) || (isKeyboard && stuckKeys[usage] == nil && isDownNow(page: kHIDPage_KeyboardOrKeypad, usage: Int(usage)))
    }

    /// `bit` as in the button byte: 0 left, 1 right, 2 middle…
    func isButtonDownNow(_ bit: Int) -> Bool {
        isMouse && isDownNow(page: kHIDPage_Button, usage: bit + 1)
    }
}

/// A physical Razer device: the set of HID interfaces sharing one USB location.
final class RazerDevice {
    let productID: Int
    let locationID: Int
    let name: String
    var interfaces: [HIDInterface] = []
    var control: RazerControl?
    var firmware: String?
    var lastModeError: String?
    /// Since when a change of device mode has been waiting for the buttons to come up.
    var modeWaitSince: Date?
    weak var manager: DeviceManager?

    /// Vendor codes currently down (report ID 4).
    var rawDown = Set<UInt8>()
    var buttons: UInt8 = 0

    init(productID: Int, locationID: Int, name: String) {
        self.productID = productID
        self.locationID = locationID
        self.name = name
    }

    var kind: DeviceKind {
        if let known = DeviceProfile.known.first(where: { $0.productID == productID }) { return known.kind }
        if let first = interfaces.first(where: { $0.number == 0 }) { return first.usbProtocol == 2 ? .mouse : .keyboard }
        return interfaces.contains(where: { $0.isMouse && !$0.isControl }) ? .mouse : .keyboard
    }

    var keysDown: Set<UInt8> { interfaces.reduce(into: Set<UInt8>()) { $0.formUnion($1.keysDown) } }

    func isKeyDownNow(_ usage: UInt8) -> Bool { interfaces.contains { $0.isKeyDownNow(usage) } }

    func isButtonDownNow(_ bit: Int) -> Bool { buttons & (1 << bit) != 0 || interfaces.contains { $0.isButtonDownNow(bit) } }

    /// Keys the device reports down that none of its buttons is holding (see `KeySlots`).
    var stuckKeys: Set<UInt8> { interfaces.reduce(into: Set<UInt8>()) { $0.formUnion($1.stuckKeys.keys) } }

    /// Whether a button is down whose meaning depends on the device mode: a keyboard's macro
    /// keys, anything on a mouse. The device mode must not change under one (see `KeySlots`).
    var hasButtonsDown: Bool {
        if !rawDown.isEmpty { return true }
        guard kind == .mouse else { return false }
        return buttons != 0 || !keysDown.isEmpty || interfaces.contains { !$0.usagesDownNow().isEmpty }
    }
}

/// The key slots of a mouse's keyboard report: the keys its buttons are typing.
///
/// A slot is not always a button being held. The firmware (a Naga X's, at least) puts a
/// button's key into the report when the button goes down and takes one such key out when it
/// comes up — whatever the button's key is at that moment, and that depends on the device
/// mode: the sixth side button is "6" in driver mode and whatever the mouse's own memory says
/// in normal mode. A button held across a change of mode therefore leaves the key it went down
/// as in every report from then on, until the mouse loses power. macOS takes that key to be
/// held, and so did we: the button was never seen to go down again.
///
/// What gives such a key away is the next press of its button, which shows the key twice. A
/// button cannot be down twice, so all but one of the copies have nothing holding them.
enum KeySlots {
    /// The keys buttons are holding, going by the slots of one report. `stuck` — the copies
    /// of each key known to be held by nothing — is brought up to date.
    static func held(in slots: some Sequence<UInt8>, stuck: inout [UInt8: Int]) -> Set<UInt8> {
        var counts: [UInt8: Int] = [:]
        for usage in slots where usage > 3 { counts[usage, default: 0] += 1 }
        for (usage, count) in counts where count - 1 > stuck[usage, default: 0] { stuck[usage] = count - 1 }
        // One that has gone was a button held after all, or the mouse has been reset.
        stuck = stuck.filter { counts[$0.key, default: 0] >= $0.value }
        return Set(counts.filter { $0.value > stuck[$0.key, default: 0] }.keys)
    }
}

final class DeviceManager {
    static let razerVendorID = 0x1532

    private let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    private(set) var devices: [RazerDevice] = []
    private var settleTimer: Timer?

    var onEvent: ((RazerDevice, KeySource, Bool) -> Void)?
    var onReport: ((RazerDevice, HIDInterface, [UInt8]) -> Void)?
    /// A device turned out to report keys down that nothing is holding, or stopped doing so.
    var onStuckKeys: ((RazerDevice) -> Void)?
    /// Called shortly after interfaces appear or disappear, once enumeration has settled.
    var onDevicesChanged: (() -> Void)?

    func start() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDVendorIDKey: Self.razerVendorID] as CFDictionary)
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            Unmanaged<DeviceManager>.fromOpaque(context!).takeUnretainedValue().attach(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            Unmanaged<DeviceManager>.fromOpaque(context!).takeUnretainedValue().detach(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
    }

    private func attach(_ hidDevice: IOHIDDevice) {
        func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(hidDevice, key as CFString) as? NSNumber)?.intValue ?? 0 }
        let productID = int(kIOHIDProductIDKey)
        let locationID = int(kIOHIDLocationIDKey)
        let name = (IOHIDDeviceGetProperty(hidDevice, kIOHIDProductKey as CFString) as? String) ?? "Razer device"

        let device: RazerDevice
        if let existing = devices.first(where: { $0.productID == productID && $0.locationID == locationID }) {
            device = existing
        } else {
            device = RazerDevice(productID: productID, locationID: locationID, name: name)
            devices.append(device)
        }
        guard !device.interfaces.contains(where: { CFEqual($0.device, hidDevice) }) else { return }

        let interface = HIDInterface(device: hidDevice)
        interface.owner = device
        device.interfaces.append(interface)
        device.interfaces.sort { $0.number < $1.number }
        // A keyboard's pointer interface carries one thing: the volume roller, which in driver mode
        // shows up as a scroll wheel. Taking it exclusively keeps it from scrolling windows.
        interface.open(seize: device.kind == .keyboard && interface.isMouse) { context, _, _, _, _, report, length in
            let interface = Unmanaged<HIDInterface>.fromOpaque(context!).takeUnretainedValue()
            interface.owner?.manager?.handleReport(interface, Array(UnsafeBufferPointer(start: report, count: length)))
        }
        device.manager = self
        // A mouse button that is already down is not a press: it is told from one by knowing
        // about it before its first report arrives.
        if device.kind == .mouse && interface.isKeyboard {
            interface.keysDown = Set(interface.usagesDownNow().compactMap { UInt8(exactly: $0) })
        }
        // A keyboard's ordinary keys, for the ones that have been given something else to do.
        // (A mouse's typed keys are read from its reports, below.)
        if device.kind == .keyboard {
            interface.watchKeys { context, _, _, value in
                let interface = Unmanaged<HIDInterface>.fromOpaque(context!).takeUnretainedValue()
                let element = IOHIDValueGetElement(value)
                let usage = IOHIDElementGetUsage(element)
                guard IOHIDElementGetUsagePage(element) == kHIDPage_KeyboardOrKeypad, (0x04...0xe7).contains(usage) else { return }
                interface.owner?.manager?.keyChanged(interface, UInt8(usage), down: IOHIDValueGetIntegerValue(value) != 0)
            }
        }
        if interface.isControl && interface.openResult == kIOReturnSuccess {
            device.control = RazerControl(device: hidDevice)
        }
        scheduleSettle()
    }

    private func detach(_ hidDevice: IOHIDDevice) {
        for device in devices {
            guard let index = device.interfaces.firstIndex(where: { CFEqual($0.device, hidDevice) }) else { continue }
            if device.interfaces[index].isControl { device.control = nil }
            device.interfaces[index].close()
            device.interfaces.remove(at: index)
        }
        let gone = devices.filter { $0.interfaces.isEmpty }
        devices.removeAll { $0.interfaces.isEmpty }
        for device in gone { log("device removed: \(device.name)") }
        scheduleSettle()
    }

    private func scheduleSettle() {
        settleTimer?.invalidate()
        settleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.onDevicesChanged?()
        }
    }

    fileprivate func handleReport(_ interface: HIDInterface, _ bytes: [UInt8]) {
        guard let device = interface.owner, !bytes.isEmpty else { return }
        onReport?(device, interface, bytes)

        if interface.isKeyboard && interface.maxInput > 8 {
            // Multi-report interface: the first byte is the report ID.
            switch bytes[0] {
            case 4:
                let now = Set(bytes.dropFirst().filter { $0 != 0 })
                emit(device, from: device.rawDown, to: now) { .raw($0) }
                device.rawDown = now
            case 1 where device.kind == .mouse:
                // [id, modifiers, key slots…]
                updateKeys(device, interface, slots: bytes.dropFirst(2))
            default:
                break
            }
        } else if interface.isKeyboard && device.kind == .mouse && bytes.count >= 8 {
            // Boot keyboard: [modifiers, reserved, 6 key slots]
            updateKeys(device, interface, slots: bytes[2..<8])
        } else if interface.isMouse && device.kind == .keyboard && bytes.count >= 4 {
            // [buttons, x, y, wheel, …]: one roller notch per unit. Reported as the same vendor
            // codes other Razer keyboards use for their volume controls.
            let notches = Int(Int8(bitPattern: bytes[3]))
            guard notches != 0 else { return }
            let source = KeySource.raw(notches > 0 ? 0x51 : 0x50)
            for _ in 0..<min(abs(notches), 8) {
                onEvent?(device, source, true)
                onEvent?(device, source, false)
            }
        } else if interface.isMouse && device.kind == .mouse {
            let now = bytes[0]
            let changed = now ^ device.buttons
            device.buttons = now
            for bit in 0..<8 where changed & (1 << bit) != 0 {
                onEvent?(device, .button(bit), now & (1 << bit) != 0)
            }
        }
    }

    /// One key of a keyboard went down or up. The same key can be reported on two interfaces;
    /// it counts as down while either says so.
    fileprivate func keyChanged(_ interface: HIDInterface, _ usage: UInt8, down: Bool) {
        guard let device = interface.owner else { return }
        var now = interface.keysDown
        if down { now.insert(usage) } else { now.remove(usage) }
        updateKeys(device, interface, now)
    }

    /// A mouse's report of the keys its buttons are typing.
    private func updateKeys(_ device: RazerDevice, _ interface: HIDInterface, slots: some Sequence<UInt8>) {
        let before = device.stuckKeys
        let held = KeySlots.held(in: slots, stuck: &interface.stuckKeys)
        updateKeys(device, interface, held)
        if device.stuckKeys != before { onStuckKeys?(device) }
    }

    private func updateKeys(_ device: RazerDevice, _ interface: HIDInterface, _ now: Set<UInt8>) {
        let before = device.keysDown
        interface.keysDown = now
        emit(device, from: before, to: device.keysDown) { .key($0) }
    }

    private func emit(_ device: RazerDevice, from old: Set<UInt8>, to new: Set<UInt8>, _ make: (UInt8) -> KeySource) {
        for code in old.subtracting(new).sorted() { onEvent?(device, make(code), false) }
        for code in new.subtracting(old).sorted() { onEvent?(device, make(code), true) }
    }
}
