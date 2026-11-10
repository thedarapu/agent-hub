// Draws the iOS app icon ("Hub": a center with three agent dots on a ring)
// into the asset catalog. Run: swift design/make-icons.swift
// Geometry is on a 100-unit grid, matching the mockup's SVG.
import AppKit

struct Palette {
    var bg: NSColor, ring: NSColor, spoke: NSColor, center: NSColor
    var dots: [NSColor] // Claude, Codex, Amp
    var transparentBg = false
}

func hex(_ v: Int, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: a)
}

let variants: [(file: String, p: Palette)] = [
    ("icon-default.png", Palette(bg: hex(0xF7F5F0), ring: hex(0x1F1E1B, 0.12), spoke: hex(0x1F1E1B, 0.30), center: hex(0x1F1E1B),
                                  dots: [hex(0xC96442), hex(0x2F6FDB), hex(0x7B5BD6)])),
    ("icon-dark.png", Palette(bg: hex(0x141311), ring: hex(0xEDEAE3, 0.12), spoke: hex(0xEDEAE3, 0.30), center: hex(0xEDEAE3),
                               dots: [hex(0xD97757), hex(0x5A8FEA), hex(0x9479E6)])),
    // Tinted: grayscale; iOS applies the tint and supplies the background.
    ("icon-tinted.png", Palette(bg: .black, ring: hex(0xFFFFFF, 0.14), spoke: hex(0xFFFFFF, 0.32), center: hex(0xF0F0F0),
                                 dots: [hex(0xC4C4C4), hex(0x8E8E8E), hex(0x6E6E6E)])),
]

let size = 1024
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1]
              : "ios/AgentHub/Support/Assets.xcassets/AppIcon.appiconset")

for (file, p) in variants {
    // No alpha channel: iOS rejects app icons with one.
    let cg = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    // 100-unit grid, y down like the SVG.
    cg.translateBy(x: 0, y: CGFloat(size)); cg.scaleBy(x: CGFloat(size) / 100, y: -CGFloat(size) / 100)

    p.bg.setFill(); NSBezierPath(rect: NSRect(x: 0, y: 0, width: 100, height: 100)).fill()

    let ring = NSBezierPath(ovalIn: NSRect(x: 50 - 28, y: 50 - 28, width: 56, height: 56))
    ring.lineWidth = 1.5; p.ring.setStroke(); ring.stroke()

    let sats = [CGPoint(x: 50, y: 22), CGPoint(x: 74.2, y: 64), CGPoint(x: 25.8, y: 64)]
    let spokes = NSBezierPath()
    for s in sats { spokes.move(to: CGPoint(x: 50, y: 50)); spokes.line(to: s) }
    spokes.lineWidth = 2.5; spokes.lineCapStyle = .round; p.spoke.setStroke(); spokes.stroke()

    func dot(_ c: CGPoint, _ r: CGFloat, _ color: NSColor) {
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)).fill()
    }
    dot(CGPoint(x: 50, y: 50), 11, p.center)
    for (s, c) in zip(sats, p.dots) { dot(s, 8, c) }

    NSGraphicsContext.restoreGraphicsState()
    let rep = NSBitmapImageRep(cgImage: cg.makeImage()!)
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(file))
    print("wrote", file)
}

let contents = """
{
  "images" : [
    { "filename" : "icon-default.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "dark" } ], "filename" : "icon-dark.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" },
    { "appearances" : [ { "appearance" : "luminosity", "value" : "tinted" } ], "filename" : "icon-tinted.png", "idiom" : "universal", "platform" : "ios", "size" : "1024x1024" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""
try! contents.write(to: out.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
