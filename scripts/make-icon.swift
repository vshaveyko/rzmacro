// Draws the app icon (a key cap with an "M" and a rainbow underglow) to a 1024px PNG.
// Usage: swift scripts/make-icon.swift out.png
import AppKit

let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let context = NSGraphicsContext.current!.cgContext

// Background plate, with the margin macOS icons leave around themselves.
let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
context.addPath(platePath)
context.clip()
let space = CGColorSpaceCreateDeviceRGB()
let background = CGGradient(colorsSpace: space, colors: [CGColor(red: 0.13, green: 0.14, blue: 0.17, alpha: 1), CGColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1)] as CFArray, locations: [0, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

// Rainbow glow under the key.
let hues: [CGFloat] = [0.0, 0.08, 0.16, 0.33, 0.5, 0.62, 0.78, 0.9]
let glow = CGGradient(colorsSpace: space, colors: hues.map { NSColor(hue: $0, saturation: 0.95, brightness: 1, alpha: 1).cgColor } as CFArray, locations: nil)!
context.saveGState()
let glowRect = CGRect(x: 250, y: 262, width: 524, height: 500)
context.setShadow(offset: .zero, blur: 70, color: CGColor(red: 1, green: 1, blue: 1, alpha: 0.35))
context.addPath(CGPath(roundedRect: glowRect, cornerWidth: 96, cornerHeight: 96, transform: nil))
context.clip()
context.drawLinearGradient(glow, start: CGPoint(x: glowRect.minX, y: 0), end: CGPoint(x: glowRect.maxX, y: 0), options: [])
context.restoreGState()

// The key cap on top of it.
let cap = CGRect(x: 274, y: 302, width: 476, height: 446)
context.addPath(CGPath(roundedRect: cap, cornerWidth: 84, cornerHeight: 84, transform: nil))
context.setFillColor(CGColor(red: 0.16, green: 0.17, blue: 0.2, alpha: 1))
context.fillPath()
context.addPath(CGPath(roundedRect: cap.insetBy(dx: 3, dy: 3), cornerWidth: 82, cornerHeight: 82, transform: nil))
context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.14))
context.setLineWidth(6)
context.strokePath()

let label = NSAttributedString(string: "M", attributes: [
    .font: NSFont.systemFont(ofSize: 300, weight: .bold),
    .foregroundColor: NSColor.white,
])
let labelSize = label.size()
label.draw(at: NSPoint(x: cap.midX - labelSize.width / 2, y: cap.midY - labelSize.height / 2 + 6))
image.unlockFocus()

let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
