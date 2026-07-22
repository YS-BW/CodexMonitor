import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: create-artwork.swift <app-icon.png> <installer-background.png>")
}

func renderPNG(size: NSSize, drawing: () -> Void) -> Data {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size.width),
        pixelsHigh: Int(size.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: representation)
    else { fatalError("Unable to create artwork bitmap") }

    representation.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawing()
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return representation.representation(using: .png, properties: [:])!
}

func systemSymbol(_ name: String, pointSize: CGFloat, weight: NSFont.Weight) -> NSImage {
    let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)!
        .withSymbolConfiguration(configuration)!
}

func drawCentered(_ image: NSImage, in rect: NSRect, alpha: CGFloat = 1) {
    image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
}

func drawPixelDog(_ image: NSImage, in rect: NSRect) {
    image.draw(
        in: rect,
        from: NSRect(x: 12, y: 2, width: 33, height: 33),
        operation: .sourceOver,
        fraction: 1
    )
}

func drawCard(_ rect: NSRect) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.07)
    shadow.shadowOffset = NSSize(width: 0, height: -4)
    shadow.shadowBlurRadius = 18
    shadow.set()
    NSColor.white.withAlphaComponent(0.72).setFill()
    NSBezierPath(roundedRect: rect, xRadius: 28, yRadius: 28).fill()
    NSGraphicsContext.restoreGraphicsState()
}

let projectRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let frameDirectory = projectRoot.appending(path: "Sources/CodexMonitor/Resources/CatFrames")
let preferredDogFrame = frameDirectory.appending(path: "elthen-idle-frame-0.png")
let fallbackDogFrame = frameDirectory.appending(path: "idle-frame-0.png")
let dogFrame = NSImage(contentsOf: preferredDogFrame) ?? NSImage(contentsOf: fallbackDogFrame)
guard let dogFrame else { fatalError("Missing pixel dog artwork") }

let iconSize = NSSize(width: 1024, height: 1024)
let iconData = renderPNG(size: iconSize) {
    NSGraphicsContext.current?.imageInterpolation = .none

    let iconRect = NSRect(x: 48, y: 48, width: 928, height: 928)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.15)
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.shadowBlurRadius = 30
    shadow.set()
    NSColor.white.setFill()
    NSBezierPath(roundedRect: iconRect, xRadius: 220, yRadius: 220).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSColor.black.withAlphaComponent(0.11).setStroke()
    let border = NSBezierPath(
        roundedRect: iconRect.insetBy(dx: 2, dy: 2),
        xRadius: 218,
        yRadius: 218
    )
    border.lineWidth = 4
    border.stroke()

    drawPixelDog(dogFrame, in: NSRect(x: 190, y: 190, width: 644, height: 644))
}

let backgroundSize = NSSize(width: 760, height: 420)
let backgroundData = renderPNG(size: backgroundSize) {
    NSGraphicsContext.current?.imageInterpolation = .high

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.95, green: 0.97, blue: 1.0, alpha: 1),
        NSColor(calibratedRed: 0.985, green: 0.985, blue: 0.995, alpha: 1),
    ])!
    gradient.draw(in: NSRect(origin: .zero, size: backgroundSize), angle: -20)

    let glow = NSGradient(colors: [
        NSColor.systemBlue.withAlphaComponent(0.12),
        NSColor.systemBlue.withAlphaComponent(0),
    ])!
    glow.draw(
        fromCenter: NSPoint(x: 380, y: 215),
        radius: 0,
        toCenter: NSPoint(x: 380, y: 215),
        radius: 290,
        options: []
    )

    let title = "Codex Monitor" as NSString
    let titleStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 29, weight: .bold),
        .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
    ]
    let titleSize = title.size(withAttributes: titleStyle)
    title.draw(
        at: NSPoint(x: (backgroundSize.width - titleSize.width) / 2, y: 357),
        withAttributes: titleStyle
    )

    let subtitle = "拖动到 Applications 完成安装" as NSString
    let subtitleStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 16, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.38, alpha: 1),
    ]
    let subtitleSize = subtitle.size(withAttributes: subtitleStyle)
    subtitle.draw(
        at: NSPoint(x: (backgroundSize.width - subtitleSize.width) / 2, y: 329),
        withAttributes: subtitleStyle
    )

    drawCard(NSRect(x: 72, y: 74, width: 236, height: 218))
    drawCard(NSRect(x: 452, y: 74, width: 236, height: 218))

    let arrow = systemSymbol("arrow.right", pointSize: 92, weight: .semibold)
    drawCentered(arrow, in: NSRect(x: 334, y: 142, width: 92, height: 92), alpha: 0.38)

    let footer = "macOS 26+  ·  Apple Silicon" as NSString
    let footerStyle: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 0.52, alpha: 1),
    ]
    let footerSize = footer.size(withAttributes: footerStyle)
    footer.draw(
        at: NSPoint(x: (backgroundSize.width - footerSize.width) / 2, y: 24),
        withAttributes: footerStyle
    )
}

try iconData.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
try backgroundData.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
