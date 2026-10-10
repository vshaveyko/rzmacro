import CoreGraphics
import Foundation

/// Session-level event tap, used to swallow what a reassigned button would otherwise have
/// done: the keystroke a thumb button types, a click, a turn of the wheel. Needs the
/// Accessibility permission.
final class EventTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var mask: CGEventMask = 0

    /// Return true to swallow the event.
    var handler: (CGEventType, CGEvent) -> Bool = { _, _ in false }

    var isRunning: Bool { port.map { CGEvent.tapIsEnabled(tap: $0) } ?? false }

    /// Taps the given kinds of event, and no others: every tapped event waits on us.
    @discardableResult
    func start(events: [CGEventType]) -> Bool {
        let mask = events.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        if port != nil && mask == self.mask { return true }
        stop()
        self.mask = mask
        let callback: CGEventTapCallBack = { _, type, event, context in
            let tap = Unmanaged<EventTap>.fromOpaque(context!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = tap.port { CGEvent.tapEnable(tap: port, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if event.getIntegerValueField(.eventSourceUserData) == MacroEngine.injectedTag {
                return Unmanaged.passUnretained(event)
            }
            return tap.handler(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        return true
    }

    func stop() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        self.source = nil
    }
}
