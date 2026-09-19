// Draws the app icon into the asset catalog. Xcode uses it directly, and
// scripts/build.sh turns the same PNGs into AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Assets.xcassets/AppIcon.appiconset"

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func circle(_ c: CGPoint, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
}

/// Draws on a 1024-point canvas; callers scale the context for smaller sizes.
func draw() {
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    // Drop shadow under the tile, as macOS icons have.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0x000000, 0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    color(0x12303F).setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Deep-water tile.
    NSGradient(colors: [color(0x1D4A5E), color(0x0C2230)])!.draw(in: shape, angle: -90)

    let c = CGPoint(x: 512, y: 512)

    // Brass ring.
    let outer = circle(c, 318)
    NSGradient(colors: [color(0xF2D58F), color(0xC99A45), color(0x8A6326)])!.draw(in: outer, angle: -60)
    color(0x5E4318, 0.9).setStroke()
    outer.lineWidth = 6
    outer.stroke()

    // Rivets around the ring.
    for k in 0..<8 {
        let a = CGFloat(k) * .pi / 4 + .pi / 8
        let p = CGPoint(x: c.x + 284 * cos(a), y: c.y + 284 * sin(a))
        NSGradient(colors: [color(0xFFF1C9), color(0xB88B3C)])!.draw(in: circle(p, 17), angle: -60)
        color(0x5E4318, 0.8).setStroke()
        let rim = circle(p, 17)
        rim.lineWidth = 3
        rim.stroke()
    }

    // Inner lip and glass.
    let lip = circle(c, 250)
    NSGradient(colors: [color(0x7A5621), color(0xD9B267)])!.draw(in: lip, angle: -60)
    let glass = circle(c, 232)
    NSGradient(colors: [color(0x0F3A4D), color(0x071820)])!.draw(in: glass, angle: -90)

    // Three status lights: two running, one orphaned.
    let lights: [(CGFloat, UInt32)] = [(-92, 0x3DDC84), (0, 0x3DDC84), (92, 0xFFAA33)]
    for (dx, hex) in lights {
        let p = CGPoint(x: c.x + dx, y: c.y - 18)
        NSGradient(colors: [color(hex, 0.55), color(hex, 0)])!.draw(in: circle(p, 62), relativeCenterPosition: .zero)
        color(hex).setFill()
        circle(p, 26).fill()
        color(0xFFFFFF, 0.55).setFill()
        circle(CGPoint(x: p.x - 8, y: p.y + 8), 8).fill()
    }

    // Reflection across the top of the glass.
    NSGraphicsContext.saveGraphicsState()
    glass.addClip()
    let sheen = NSBezierPath()
    sheen.appendArc(withCenter: CGPoint(x: c.x - 40, y: c.y + 60), radius: 230, startAngle: 20, endAngle: 160)
    sheen.appendArc(withCenter: CGPoint(x: c.x - 40, y: c.y + 10), radius: 230, startAngle: 160, endAngle: 20, clockwise: true)
    sheen.close()
    color(0xFFFFFF, 0.10).setFill()
    sheen.fill()
    NSGraphicsContext.restoreGraphicsState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    context.cgContext.scaleBy(x: scale, y: scale)
    draw()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: out)
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    try! png(pixels: size).write(to: dir.appendingPathComponent("icon_\(size)x\(size).png"))
    try! png(pixels: size * 2).write(to: dir.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
print("Wrote \(out)")
