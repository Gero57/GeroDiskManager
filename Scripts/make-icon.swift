import AppKit
import Foundation

// Bright, neutral icon: a pearl-white glass tile with a graphite drive and a blue status light.
let size = NSSize(width: 1024, height: 1024)
let image = NSImage(size: size)
image.lockFocus()
let bounds = NSRect(origin: .zero, size: size)
let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 24, dy: 24), xRadius: 220, yRadius: 220)

let background = NSGradient(colors: [
    NSColor(calibratedRed: 0.99, green: 0.995, blue: 1.0, alpha: 1),
    NSColor(calibratedRed: 0.86, green: 0.93, blue: 0.99, alpha: 1),
    NSColor(calibratedRed: 0.72, green: 0.86, blue: 0.96, alpha: 1)
])!
background.draw(in: card, angle: -45)

let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 26, dy: 26), xRadius: 218, yRadius: 218)
NSColor(calibratedWhite: 1.0, alpha: 0.9).setStroke()
border.lineWidth = 8
border.stroke()

let symbol = NSImage(systemSymbolName: "externaldrive.fill", accessibilityDescription: "Gero Disk Manager")!
let palette = NSImage.SymbolConfiguration.palette([
    NSColor(calibratedRed: 0.16, green: 0.22, blue: 0.29, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.48, blue: 0.82, alpha: 1)
])
let config = NSImage.SymbolConfiguration(pointSize: 540, weight: .regular).applying(palette)
let styled = symbol.withSymbolConfiguration(config)!
let rect = NSRect(x: 170, y: 205, width: 684, height: 614)
styled.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)

image.unlockFocus()
let tiff = image.tiffRepresentation!
let bitmap = NSBitmapImageRep(data: tiff)!
let png = bitmap.representation(using: .png, properties: [:])!
try png.write(to: URL(fileURLWithPath: "AppIcon.png"))
