import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: create-artwork.swift <app-icon.png> <installer-background.png>")
}

func pngData(for image: NSImage) -> Data {
    let representation = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return representation.representation(using: .png, properties: [:])!
}

func symbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(configuration)!
}

func drawCentered(_ image: NSImage, in rect: NSRect, alpha: CGFloat = 1) {
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
}

let icon = NSImage(size: NSSize(width: 1024, height: 1024))
icon.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high

let iconRect = NSRect(x: 48, y: 48, width: 928, height: 928)
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
shadow.shadowOffset = NSSize(width: 0, height: -18)
shadow.shadowBlurRadius = 28
shadow.set()
NSColor.white.setFill()
NSBezierPath(roundedRect: iconRect, xRadius: 220, yRadius: 220).fill()

NSColor.black.withAlphaComponent(0.12).setStroke()
let border = NSBezierPath(roundedRect: iconRect.insetBy(dx: 2, dy: 2), xRadius: 218, yRadius: 218)
border.lineWidth = 4
border.stroke()

let sparkle = symbol("sparkles", pointSize: 450, weight: .medium)
drawCentered(sparkle, in: NSRect(x: 287, y: 287, width: 450, height: 450))
icon.unlockFocus()

let background = NSImage(size: NSSize(width: 760, height: 460))
background.lockFocus()
NSGraphicsContext.current?.imageInterpolation = .high
NSColor(calibratedRed: 0.965, green: 0.972, blue: 0.984, alpha: 1).setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: background.size)).fill()

let title = "Install Codex Monitor" as NSString
let titleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
    .foregroundColor: NSColor(calibratedWhite: 0.16, alpha: 1)
]
let titleSize = title.size(withAttributes: titleStyle)
title.draw(
    at: NSPoint(x: (background.size.width - titleSize.width) / 2, y: 390),
    withAttributes: titleStyle
)

let subtitle = "Drag the app to Applications" as NSString
let subtitleStyle: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 17, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.42, alpha: 1)
]
let subtitleSize = subtitle.size(withAttributes: subtitleStyle)
subtitle.draw(
    at: NSPoint(x: (background.size.width - subtitleSize.width) / 2, y: 360),
    withAttributes: subtitleStyle
)

let arrow = symbol("arrow.right", pointSize: 130, weight: .semibold)
drawCentered(arrow, in: NSRect(x: 318, y: 168, width: 124, height: 124), alpha: 0.16)
background.unlockFocus()

try pngData(for: icon).write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
try pngData(for: background).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
