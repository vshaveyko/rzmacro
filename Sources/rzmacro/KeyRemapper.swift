import Foundation
import IOKit.hid
import IOKit.hidsystem

extension Assignment {
    /// The one key this turns a keyboard key into, as the keyboard driver names keys (usage
    /// page and usage in one number) — or nil if it is anything more than a plain swap.
    var remapTarget: UInt64? {
        guard hold, repeatMs == nil, steps.count == 1, case .tap(let chord) = steps[0] else { return nil }
        if chord.keyName == nil, chord.modifiers.count == 1 { return chord.modifiers[0].usage }
        guard chord.modifiers.isEmpty, let usage = chord.keyName.flatMap({ Keys.usageByName[$0] }), usage != 0 else { return nil }
        return UInt64(kHIDPage_KeyboardOrKeypad) << 32 | UInt64(usage)
    }
}

/// Changes what a keyboard's ordinary keys are, in the keyboard driver itself — the mechanism
/// behind `hidutil property --set UserKeyMapping`, applied only to the keyboards RZMacro
/// looks after.
///
/// A key can become another key (Caps Lock into Escape), which then behaves like the real one
/// everywhere: held, repeating, in games, in password fields. Or it can become nothing, which
/// is how a key that runs a macro stops typing its own letter; the macro itself is started
/// from the device's report, like any other button's. The mapping belongs to the keyboard's
/// connection to macOS: it is gone when the keyboard is unplugged, and has to be taken off
/// when the driver quits.
final class KeyRemapper {
    /// Where a key that should do nothing is sent: the driver drops a key mapped to zero.
    static let nothing: UInt64 = 0

    private static let property = kIOHIDUserKeyUsageMapKey as CFString
    /// Remembered across launches: after a crash the keyboard still has our mapping on it.
    private static let appliedKey = "keyRemapApplied"

    private var applied: Bool {
        get { UserDefaults.standard.bool(forKey: Self.appliedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.appliedKey) }
    }

    /// What the last `apply` did, for `rzmacro status`.
    private(set) var status = "none"

    /// The keyboards' services, as last looked up, and the client they belong to. Looking them
    /// up means asking every input service on the Mac what it is — a couple of hundred — so it
    /// is done when devices change, not every time the profile does.
    private var found: (keyboards: Set<DeviceID>, client: IOHIDEventSystemClient, services: [IOHIDServiceClient])?
    /// The mapping each service was last given, by its registry id. A service can't usefully
    /// be asked: setting a mapping lets go of whatever remapped keys are held, so it is set
    /// only on a service that hasn't been given this one — a keyboard just plugged in, say.
    private var given: [UInt64: (service: IOHIDServiceClient, map: [UInt64: UInt64])] = [:]

    /// Devices came or went: the services have to be looked up again.
    func devicesChanged() { found = nil }

    /// The keyboard-typing services of the given models.
    private func services(keyboards: Set<DeviceID>) -> [IOHIDServiceClient] {
        guard !keyboards.isEmpty else { return [] }
        if let found, found.keyboards == keyboards { return found.services }
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient] ?? []
        let services = all.filter { service in
            func number(_ key: String) -> Int { (IOHIDServiceClientCopyProperty(service, key as CFString) as? NSNumber)?.intValue ?? 0 }
            return keyboards.contains(DeviceID(vendor: number(kIOHIDVendorIDKey), product: number(kIOHIDProductIDKey)))
                && IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Keyboard)) != 0
        }
        found = (keyboards, client, services)
        return services
    }

    /// Makes `map` — keyboard usage to what it becomes — the mapping of every one of
    /// `keyboards`, and takes ours off any keyboard that is no longer among them.
    func apply(_ map: [UInt8: UInt64], keyboards: Set<DeviceID>) {
        let wanted = Dictionary(uniqueKeysWithValues: map.map { (UInt64(kHIDPage_KeyboardOrKeypad) << 32 | UInt64($0.key), $0.value) })
        // Nothing to map and nothing of ours left behind: leave the keyboards as they are,
        // including any mapping the user made with hidutil.
        guard !wanted.isEmpty || applied else {
            status = "none"
            return
        }
        let pairs = wanted.map {
            [kIOHIDKeyboardModifierMappingSrcKey: NSNumber(value: $0.key), kIOHIDKeyboardModifierMappingDstKey: NSNumber(value: $0.value)]
        }
        let services = services(keyboards: keyboards)
        var ids = Set<UInt64>(), refused = 0
        for service in services {
            let id = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value ?? 0
            ids.insert(id)
            guard given[id]?.map != wanted else { continue }
            if IOHIDServiceClientSetProperty(service, Self.property, pairs as CFArray) { given[id] = (service, wanted) } else { refused += 1 }
        }
        // A keyboard we have stopped looking after gets its keys back. (One that has been
        // unplugged took the mapping with it; telling it so fails and does not matter.)
        for (id, last) in given where !ids.contains(id) {
            if !last.map.isEmpty { IOHIDServiceClientSetProperty(last.service, Self.property, [] as CFArray) }
            given[id] = nil
        }
        // With no keyboard to ask, what a crash may have left on one is still unknown.
        if !services.isEmpty { applied = !wanted.isEmpty }

        let swapped = wanted.values.filter { $0 != Self.nothing }.count
        if wanted.isEmpty {
            status = "none"
        } else if services.isEmpty {
            status = "\(wanted.count) waiting for a keyboard"
        } else if refused > 0 {
            status = "\(wanted.count) NOT APPLIED (macOS would not take the mapping)"
        } else {
            status = "\(swapped) swapped by the keyboard driver, \(wanted.count - swapped) taken over by rzmacro"
        }
    }

    /// Hands every keyboard back unmapped.
    func clear(keyboards: Set<DeviceID>) {
        apply([:], keyboards: keyboards)
    }
}
