import AppKit

guard CommandLine.arguments.count == 3 else {
    fputs("Usage: create-xiaohongshu-poster.swift <product-screenshot> <output-png>\n", stderr)
    exit(1)
}

let screenshotURL = URL(fileURLWithPath: CommandLine.arguments[1])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[2])
guard let screenshot = NSImage(contentsOf: screenshotURL) else {
    fputs("Unable to load product screenshot.\n", stderr)
    exit(1)
}

let canvasSize = NSSize(width: 1242, height: 1660)
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvasSize.width),
    pixelsHigh: Int(canvasSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
    fputs("Unable to create output bitmap.\n", stderr)
    exit(1)
}

func rect(top: CGFloat, left: CGFloat, width: CGFloat, height: CGFloat) -> NSRect {
    NSRect(x: left, y: canvasSize.height - top - height, width: width, height: height)
}

func drawText(_ text: String, in frame: NSRect, font: NSFont, color: NSColor, lineSpacing: CGFloat = 0, alignment: NSTextAlignment = .left) {
    let style = NSMutableParagraphStyle()
    style.alignment = alignment
    style.lineSpacing = lineSpacing
    let attributed = NSAttributedString(
        string: text,
        attributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
    )
    attributed.draw(in: frame)
}

func roundedRect(_ frame: NSRect, radius: CGFloat, color: NSColor, border: NSColor? = nil) {
    let path = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
    color.setFill()
    path.fill()
    if let border {
        border.setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

func featureCard(top: CGFloat, title: String, eyebrow: String, detail: String, isBlue: Bool) {
    let frame = rect(top: top, left: 730, width: 448, height: 350)
    let fill = isBlue
        ? NSColor(calibratedRed: 0.04, green: 0.45, blue: 0.96, alpha: 0.96)
        : NSColor(calibratedWhite: 1, alpha: 0.84)
    roundedRect(frame, radius: 34, color: fill, border: isBlue ? nil : NSColor(calibratedWhite: 1, alpha: 0.96))

    let primary = isBlue ? NSColor.white : NSColor(calibratedRed: 0.04, green: 0.12, blue: 0.23, alpha: 1)
    let secondary = isBlue ? NSColor.white.withAlphaComponent(0.88) : NSColor(calibratedWhite: 0.31, alpha: 1)
    drawText(eyebrow, in: NSRect(x: frame.minX + 34, y: frame.maxY - 66, width: 360, height: 26), font: .systemFont(ofSize: 22, weight: .bold), color: secondary)
    drawText(title, in: NSRect(x: frame.minX + 32, y: frame.maxY - 148, width: 380, height: 82), font: .systemFont(ofSize: 58, weight: .bold), color: primary)
    drawText(detail, in: NSRect(x: frame.minX + 34, y: frame.minY + 50, width: 368, height: 68), font: .systemFont(ofSize: 27, weight: .semibold), color: secondary, lineSpacing: 7)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = graphicsContext
defer { NSGraphicsContext.restoreGraphicsState() }

// Editorial, warm-white backdrop inspired by the supplied social-poster references.
let fullFrame = NSRect(origin: .zero, size: canvasSize)
NSGradient(colors: [
    NSColor(calibratedRed: 0.96, green: 0.975, blue: 0.99, alpha: 1),
    NSColor(calibratedRed: 0.90, green: 0.93, blue: 0.97, alpha: 1)
])?.draw(in: fullFrame, angle: -20)

NSColor(calibratedWhite: 1, alpha: 0.55).setFill()
NSBezierPath(ovalIn: NSRect(x: -120, y: 980, width: 920, height: 660)).fill()
NSColor(calibratedRed: 0.23, green: 0.55, blue: 0.98, alpha: 0.10).setFill()
NSBezierPath(ovalIn: NSRect(x: 500, y: 70, width: 900, height: 950)).fill()

// Header.
let accent = NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.92, alpha: 1)
drawText("Codex Monitor · macOS 菜单栏工具", in: rect(top: 62, left: 70, width: 1000, height: 38), font: .systemFont(ofSize: 25, weight: .semibold), color: accent)
roundedRect(rect(top: 112, left: 70, width: 74, height: 5), radius: 2.5, color: accent)
drawText("把 Codex 装进菜单栏", in: rect(top: 145, left: 66, width: 1120, height: 112), font: .systemFont(ofSize: 82, weight: .bold), color: NSColor(calibratedRed: 0.045, green: 0.09, blue: 0.16, alpha: 1))
drawText("额度、Token、趋势与会话，一眼掌握", in: rect(top: 274, left: 72, width: 1100, height: 38), font: .systemFont(ofSize: 27, weight: .semibold), color: NSColor(calibratedWhite: 0.30, alpha: 1))

// Product screenshot: deliberately drawn as the untouched source of truth.
let productFrame = rect(top: 370, left: 62, width: 620, height: 1092)
let productPath = NSBezierPath(roundedRect: productFrame, xRadius: 35, yRadius: 35)
let shadow = NSShadow()
shadow.shadowColor = NSColor(calibratedRed: 0.02, green: 0.10, blue: 0.22, alpha: 0.28)
shadow.shadowBlurRadius = 34
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor.white.setFill()
productPath.fill()
NSGraphicsContext.current?.saveGraphicsState()
productPath.addClip()
screenshot.draw(in: productFrame, from: NSRect(origin: .zero, size: screenshot.size), operation: .sourceOver, fraction: 1)
NSGraphicsContext.current?.restoreGraphicsState()
NSColor(calibratedWhite: 1, alpha: 0.76).setStroke()
productPath.lineWidth = 2
productPath.stroke()

// Two large, independently readable feature cards for mobile feeds.
featureCard(top: 400, title: "模块化", eyebrow: "01 / 按需组合", detail: "额度 · Token · 趋势 · 会话\n只保留你关心的信息", isBlue: false)
featureCard(top: 800, title: "拖拽排序", eyebrow: "02 / 自由排列", detail: "整块按住拖动\n跨过中心线，立即让位", isBlue: true)

drawText("Codex Monitor  ·  github.com/YS-BW/CodexMonitor", in: rect(top: 1604, left: 84, width: 1080, height: 30), font: .systemFont(ofSize: 18, weight: .medium), color: NSColor(calibratedWhite: 0.34, alpha: 1), alignment: .center)

guard let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("Unable to encode PNG.\n", stderr)
    exit(1)
}
try png.write(to: outputURL)
