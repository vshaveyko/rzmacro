import CoreGraphics
import Foundation

/// Everything that is specific to one device model: which special buttons it has, where they
/// are in its picture, and how its LEDs are addressed. Supporting another Razer device means
/// adding an entry to `known`; anything not listed still works through `generic`.
struct DeviceProfile {
    struct Key: Identifiable {
        let source: KeySource
        let label: String
        /// Full name, where the group and label don't make one ("Wheel click").
        var name: String?
        /// Heading the button is listed under.
        let group: String
        /// What it does when nothing is assigned.
        let defaultBehaviour: String
        /// Fires once per notch (a roller): holding and repeating mean nothing.
        var isMomentary = false
        /// Where the button is in the product photo, in the photo's pixels.
        var hotspot: CGRect?

        var id: KeySource { source }
    }

    /// The manufacturer's product photo. It is their image, so it is not shipped with the app:
    /// the app draws the device itself, and downloads the photo only if the user asks for it.
    struct Picture {
        /// Name it is stored under once downloaded.
        let file: String
        /// Where Razer publishes it.
        let url: String
        /// The part of the picture worth showing, in pixels.
        let crop: CGRect
        /// The crop cuts the device off at the bottom (to show its buttons larger).
        var fadesOut = false
    }

    /// nil for the generic profile.
    let productID: Int?
    let kind: DeviceKind
    let keys: [Key]
    /// How many buttons per row the list should show, when the real thing is a grid.
    var listColumns: Int?
    let picture: Picture?
    let lights: LightLayout

    static let known: [DeviceProfile] = [blackWidowV4X, nagaX]

    static func profile(productID: Int, kind: DeviceKind) -> DeviceProfile {
        known.first { $0.productID == productID } ?? generic(kind)
    }

    /// The model each page shows while nothing of that kind is plugged in.
    static func preferred(for kind: DeviceKind) -> DeviceProfile {
        known.first { $0.kind == kind } ?? generic(kind)
    }

    /// Any other Razer keyboard or mouse. Its special buttons are not known in advance — the
    /// app lists them as they are pressed — and its lighting gets one colour per zone, set with
    /// the plain "static" command, since the LED matrix size is unknown.
    static func generic(_ kind: DeviceKind) -> DeviceProfile {
        DeviceProfile(
            productID: nil, kind: kind, keys: kind == .mouse ? standardMouseKeys(sideButtons: true) : [], listColumns: nil, picture: nil,
            lights: kind == .keyboard
                ? LightLayout(transport: .uniform, zones: [0x05], positions: [0.4])
                : LightLayout(transport: .uniform, zones: [0x01, 0x04], positions: [0.95, 0.95]))
    }

    /// What a mouse has besides its special buttons. The left button is not offered: taking
    /// it away by accident would leave no way to click on anything, this app included.
    static func standardMouseKeys(sideButtons: Bool) -> [Key] {
        let group = "Buttons and wheel"
        var keys = [
            Key(source: .button(1), label: "Right", name: "Right button", group: group, defaultBehaviour: "Right click"),
            Key(source: .button(2), label: "Wheel", name: "Wheel click", group: group, defaultBehaviour: "Middle click"),
            Key(source: .wheel(up: true), label: "▲", name: "Wheel up", group: group, defaultBehaviour: "Scrolls up", isMomentary: true),
            Key(source: .wheel(up: false), label: "▼", name: "Wheel down", group: group, defaultBehaviour: "Scrolls down", isMomentary: true),
        ]
        if sideButtons {
            keys += [
                Key(source: .button(3), label: "Back", name: "Back button", group: group, defaultBehaviour: "Back"),
                Key(source: .button(4), label: "Fwd", name: "Forward button", group: group, defaultBehaviour: "Forward"),
            ]
        }
        return keys
    }

    // MARK: Known models

    private static let blackWidowV4X = DeviceProfile(
        productID: 0x0293,
        kind: .keyboard,
        keys: (0..<6).map { index in
            // A column of six down the left edge, one per keyboard row.
            let top: [CGFloat] = [230, 256, 277, 298, 319, 340]
            return Key(source: .raw(UInt8(0x20 + index)), label: "M\(index + 1)", group: "Macro keys",
                       defaultBehaviour: "No action", hotspot: CGRect(x: 59, y: top[index], width: 20, height: 19))
        } + [
            Key(source: .raw(0x51), label: "▲", group: "Volume roller", defaultBehaviour: "Volume up",
                isMomentary: true, hotspot: CGRect(x: 474, y: 212, width: 27, height: 18)),
            Key(source: .raw(0x50), label: "▼", group: "Volume roller", defaultBehaviour: "Volume down",
                isMomentary: true, hotspot: CGRect(x: 501, y: 212, width: 27, height: 18)),
        ],
        listColumns: nil,
        picture: Picture(file: "0293.png", url: "https://dl.razerzone.com/src2/13223/13223-1-en-v1.png", crop: CGRect(x: 42, y: 198, width: 516, height: 190)),
        // 6 x 22 key matrix behind one backlight zone; frame packets are always 0x47 long.
        lights: LightLayout(transport: .frames(rows: 6, packetSize: 0x47), zones: [0x05], positions: (0..<22).map { Double($0) / 21 * 0.8 }))

    private static let nagaX = DeviceProfile(
        productID: 0x0096,
        kind: .mouse,
        keys: {
            // In driver mode the thumb grid types the number row, whatever is stored on the mouse.
            let usages: [UInt8] = [0x1e, 0x1f, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2d, 0x2e]
            let typed = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="]
            let centre: [CGPoint] = [
                CGPoint(x: 186, y: 309), CGPoint(x: 205, y: 302), CGPoint(x: 227, y: 295),
                CGPoint(x: 187, y: 340), CGPoint(x: 208, y: 334), CGPoint(x: 232, y: 327),
                CGPoint(x: 190, y: 372), CGPoint(x: 210, y: 366), CGPoint(x: 237, y: 359),
                CGPoint(x: 192, y: 402), CGPoint(x: 213, y: 395), CGPoint(x: 238, y: 387),
            ]
            return (0..<12).map { index in
                Key(source: .key(usages[index]), label: "\(index + 1)", group: "Thumb grid",
                    defaultBehaviour: "Types “\(typed[index])”",
                    hotspot: CGRect(x: centre[index].x - 9, y: centre[index].y - 9, width: 18, height: 18))
            } + standardMouseKeys(sideButtons: false)
        }(),
        listColumns: 3,
        // Zoomed on the upper two thirds, where the thumb grid is.
        picture: Picture(file: "0096.png", url: "https://dl.razerzone.com/src/3993-1-EN-V2.png", crop: CGRect(x: 160, y: 112, width: 268, height: 352), fadesOut: true),
        // Two LEDs, thumb grid and scroll wheel, addressed as a 1 x 2 matrix.
        lights: LightLayout(transport: .frames(rows: 1, packetSize: nil), zones: [0x01, 0x11], positions: [0.92, 0.97]))
}
