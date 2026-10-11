import Foundation

/// Which model a USB device is: its vendor and product numbers, written "05ac:024f".
struct DeviceID: Hashable, CustomStringConvertible {
    let vendor: Int
    let product: Int

    var description: String { String(format: "%04x:%04x", vendor, product) }

    init(vendor: Int, product: Int) {
        self.vendor = vendor
        self.product = product
    }

    init?(_ text: String) {
        let parts = text.split(separator: ":").map { Int($0, radix: 16) }
        guard parts.count == 2, let vendor = parts[0], let product = parts[1], (0...0xffff).contains(vendor), (0...0xffff).contains(product) else { return nil }
        self.init(vendor: vendor, product: product)
    }
}

/// How much of a keyboard a keyboard has, for drawing it.
enum KeyboardShape: String, CaseIterable {
    case full
    /// No number pad.
    case tenkeyless = "tkl"
    /// Function row and arrows, the navigation keys in a column down the right edge.
    case compact75 = "75%"
    /// The same without the function row.
    case compact65 = "65%"
    /// The main block alone.
    case compact60 = "60%"

    var title: String {
        switch self {
        case .full: return "Full size"
        case .tenkeyless: return "Tenkeyless"
        case .compact75: return "75%"
        case .compact65: return "65%"
        case .compact60: return "60%"
        }
    }

    /// The shape of a keyboard that says what model it is, where that is one we know.
    static func guess(name: String) -> KeyboardShape {
        let words = Set(name.uppercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
        guard words.contains("KEYCHRON") else { return .full }
        if !words.isDisjoint(with: ["K2", "K3"]) { return .compact75 }
        if words.contains("K6") { return .compact65 }
        if words.contains("K8") { return .tenkeyless }
        if words.contains("K12") { return .compact60 }
        return .full
    }
}

/// A keyboard that is not Razer's, which RZMacro has been asked to look after as well. Its
/// ordinary keys can be given other things to do, like a Razer keyboard's; lighting and macro
/// keys are the Razer devices' alone.
///
/// It is by request only: RZMacro reads which keys are pressed on a keyboard it looks after,
/// and that is not something to start doing to every keyboard that gets plugged in.
struct OtherKeyboard: Equatable {
    var id: DeviceID
    /// What it called itself when it was added: something to list it by while it is unplugged.
    var name: String
    var shape: KeyboardShape

    init(id: DeviceID, name: String, shape: KeyboardShape? = nil) {
        self.id = id
        self.name = name
        self.shape = shape ?? KeyboardShape.guess(name: name)
    }
}
