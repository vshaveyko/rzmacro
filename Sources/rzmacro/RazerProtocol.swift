import Foundation
import IOKit
import IOKit.hid

enum RazerError: Error, CustomStringConvertible {
    case io(String, IOReturn)
    case status(UInt8)
    case noResponse

    var description: String {
        switch self {
        case .io(let what, let code): return String(format: "%@ failed (0x%08x)", what, UInt32(bitPattern: code))
        case .status(let s): return String(format: "device answered status 0x%02x (%@)", s, RazerControl.statusName(s))
        case .noResponse: return "no response"
        }
    }
}

enum DeviceMode: UInt8 {
    /// Firmware handles everything itself (on-board profile).
    case normal = 0x00
    /// Buttons assigned to "no function" and special keys are reported raw on report ID 4.
    case driver = 0x03
}

/// Razer's vendor protocol: a 90-byte feature report (ID 0) written to and read back from
/// the device's control interface.
///
///     0     status           0x00 new, 0x01 busy, 0x02 ok, 0x03 fail, 0x04 timeout, 0x05 unsupported
///     1     transaction id   device family specific (0x1f for both devices this was written for)
///     2-3   remaining packets
///     4     protocol type
///     5     data size
///     6     command class
///     7     command id       bit 7 set = "get"
///     8-87  arguments
///     88    crc              xor of bytes 2..87
///     89    reserved
final class RazerControl {
    static let reportLength = 90
    static let candidateTransactionIDs: [UInt8] = [0x1f, 0xff, 0x3f, 0x9f, 0x08]

    let device: IOHIDDevice
    private(set) var transactionID: UInt8?
    /// Commands come from the main thread and from the lighting thread; a request and the read
    /// of its answer must not be interleaved with another request.
    private let lock = NSLock()

    init(device: IOHIDDevice) { self.device = device }

    static func statusName(_ s: UInt8) -> String {
        ["new", "busy", "ok", "failure", "timeout", "not supported"][safe: Int(s)] ?? "unknown"
    }

    /// Sends a command and returns the full 90-byte response. Throws unless the device answers "ok".
    @discardableResult
    func send(class cls: UInt8, id: UInt8, size: UInt8, args: [UInt8] = []) throws -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        if let tid = transactionID { return try transact(tid, cls, id, size, args) }
        var lastError: Error = RazerError.noResponse
        for tid in Self.candidateTransactionIDs {
            do {
                let response = try transact(tid, cls, id, size, args)
                transactionID = tid
                return response
            } catch let error as RazerError {
                if case .io = error { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /// Sends a command without reading the answer — for streaming lighting frames, where the
    /// round trip would halve the frame rate and the answer carries nothing.
    func post(class cls: UInt8, id: UInt8, size: UInt8, args: [UInt8]) throws {
        lock.lock()
        defer { lock.unlock() }
        var request = Self.request(transactionID ?? Self.candidateTransactionIDs[0], cls, id, size, args)
        let result = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, &request, request.count)
        guard result == kIOReturnSuccess else { throw RazerError.io("SetReport", result) }
        usleep(900)
    }

    private static func request(_ tid: UInt8, _ cls: UInt8, _ id: UInt8, _ size: UInt8, _ args: [UInt8]) -> [UInt8] {
        var request = [UInt8](repeating: 0, count: reportLength)
        request[1] = tid
        request[5] = size
        request[6] = cls
        request[7] = id
        for (i, value) in args.prefix(80).enumerated() { request[8 + i] = value }
        request[88] = request[2..<88].reduce(0, ^)
        return request
    }

    private func transact(_ tid: UInt8, _ cls: UInt8, _ id: UInt8, _ size: UInt8, _ args: [UInt8]) throws -> [UInt8] {
        var request = Self.request(tid, cls, id, size, args)

        let setResult = IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, 0, &request, request.count)
        guard setResult == kIOReturnSuccess else { throw RazerError.io("SetReport", setResult) }

        var response = [UInt8](repeating: 0, count: Self.reportLength)
        for _ in 0..<25 {
            usleep(8_000)
            var length = response.count
            let getResult = IOHIDDeviceGetReport(device, kIOHIDReportTypeFeature, 0, &response, &length)
            guard getResult == kIOReturnSuccess else { throw RazerError.io("GetReport", getResult) }
            if response[0] != 0x01 { break }
        }
        // Someone else (e.g. Razer's own software) may be talking to the device at the same time.
        guard response[6] == cls, response[7] == id else { throw RazerError.noResponse }
        guard response[0] == 0x02 else { throw RazerError.status(response[0]) }
        return response
    }

    // MARK: Commands

    func firmwareVersion() throws -> String {
        let r = try send(class: 0x00, id: 0x81, size: 0x02)
        return "\(r[8]).\(r[9])"
    }

    func deviceMode() throws -> UInt8 {
        try send(class: 0x00, id: 0x84, size: 0x02)[8]
    }

    func setDeviceMode(_ mode: DeviceMode) throws {
        try send(class: 0x00, id: 0x04, size: 0x02, args: [mode.rawValue, 0x00])
    }

    /// Hardware brightness of one LED zone, 0...255.
    func brightness(led: UInt8) throws -> UInt8 {
        try send(class: 0x0f, id: 0x84, size: 0x03, args: [0x01, led])[10]
    }

    func setBrightness(_ value: UInt8, led: UInt8) throws {
        try send(class: 0x0f, id: 0x04, size: 0x03, args: [0x01, led, value])
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
