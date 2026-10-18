// Draws the watch-mcp / WatchRecorder logo (an eye whose pupil is a play button, plus a red
// record dot) and writes the macOS app icon and the README logo.
// Usage: swift companion/Scripts/make-icon.swift <repository root>
import AppKit

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

/// Draws the logo in a size x size square. `tile`: draw the rounded-square background.
func drawLogo(size: CGFloat, tile: Bool) {
    let s = size / 1024
    if tile {
        let rect = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let squircle = NSBezierPath(roundedRect: rect, xRadius: 186 * s, yRadius: 186 * s)
        NSGraphicsContext.current?.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = color(0x000000, 0.35)
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.shadowBlurRadius = 24 * s
        shadow.set()
        color(0x1E1B4B).setFill()
        squircle.fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSGradient(colors: [color(0x4F46E5), color(0x1E1B4B)])?.draw(in: squircle, angle: -60)
    }
    // Eye: two arcs meeting at the corners.
    let cx = 512 * s, cy = 512 * s
    let half = 300 * s, lift = 210 * s
    let eye = NSBezierPath()
    eye.move(to: NSPoint(x: cx - half, y: cy))
    eye.curve(to: NSPoint(x: cx + half, y: cy), controlPoint1: NSPoint(x: cx - half * 0.45, y: cy + lift), controlPoint2: NSPoint(x: cx + half * 0.45, y: cy + lift))
    eye.curve(to: NSPoint(x: cx - half, y: cy), controlPoint1: NSPoint(x: cx + half * 0.45, y: cy - lift), controlPoint2: NSPoint(x: cx - half * 0.45, y: cy - lift))
    eye.close()
    color(0xF8FAFC).setFill()
    eye.fill()
    // Iris, then a play triangle as the pupil.
    let r = 118 * s
    let iris = NSBezierPath(ovalIn: NSRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r))
    NSGradient(colors: [color(0x6366F1), color(0x312E81)])?.draw(in: iris, angle: -90)
    let t = 52 * s
    let play = NSBezierPath()
    play.move(to: NSPoint(x: cx - t * 0.7, y: cy - t))
    play.line(to: NSPoint(x: cx - t * 0.7, y: cy + t))
    play.line(to: NSPoint(x: cx + t * 1.05, y: cy))
    play.close()
    color(0xFFFFFF).setFill()
    play.fill()
    // Record dot.
    let d = 64 * s
    let dot = NSBezierPath(ovalIn: NSRect(x: 724 * s - d, y: 724 * s - d, width: 2 * d, height: 2 * d))
    color(0xF43F5E).setFill()
    dot.fill()
    color(0xFFFFFF, 0.9).setStroke()
    dot.lineWidth = 10 * s
    dot.stroke()
}

func png(size: Int, tile: Bool) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawLogo(size: CGFloat(size), tile: tile)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try png(size: base, tile: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try png(size: base * 2, tile: true).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let icns = root.appendingPathComponent("companion/Resources/AppIcon.icns")
let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try iconutil.run()
iconutil.waitUntilExit()
try FileManager.default.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
try png(size: 512, tile: true).write(to: root.appendingPathComponent("docs/logo.png"))
print("wrote \(icns.path) and docs/logo.png")
