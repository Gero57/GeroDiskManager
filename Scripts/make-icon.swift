import AppKit
import Foundation

let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let bounds = NSRect(origin: .zero, size: size)
let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 24, dy: 24), xRadius: 210, yRadius: 210)
let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.025, green: 0.10, blue: 0.22, alpha: 1),
    NSColor(calibratedRed: 0.02, green: 0.30, blue: 0.58, alpha: 1),
    NSColor(calibratedRed: 0.015, green: 0.045, blue: 0.12, alpha: 1)
])!
gradient.draw(in: card, angle: -45)
let symbol = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "Gero Disk Manager")!
let config = NSImage.SymbolConfiguration(pointSize: 520, weight: .regular)
let styled = symbol.withSymbolConfiguration(config)!
let rect = NSRect(x: 185, y: 205, width: 654, height: 614)
styled.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
image.unlockFocus()

let tiff = image.tiffRepresentation!
let bitmap = NSBitmapImageRep(data: tiff)!
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: "AppIcon.png"))
