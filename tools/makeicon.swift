import AppKit
import Foundation

// Generates the macOS AppIcon set for MyTokens — a gradient brass key on a dark
// graphite "vault" squircle, echoing SecretPromptView's brass-key identity.
// Vector-drawn at each required pixel size (crisp, reproducible). Run via `make icon`.
//   swift tools/makeicon.swift [outputDir]

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Assets.xcassets/AppIcon.appiconset"

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> NSColor {
    NSColor(srgbRed: r, green: g, blue: b, alpha: 1)
}
let brassLight = rgb(0.88, 0.66, 0.34)
let brassDark  = rgb(0.60, 0.37, 0.13)
let brass      = rgb(0.66, 0.42, 0.16)
let plateTop   = rgb(0.22, 0.22, 0.25)
let plateBot   = rgb(0.086, 0.086, 0.098)

// A gradient-filled key glyph (brass, top-lit).
func brassKey(pointSize: CGFloat) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .bold)
    let sym = NSImage(systemSymbolName: "key.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(cfg)!
    let sz = sym.size
    let out = NSImage(size: sz)
    out.lockFocus()
    sym.draw(in: NSRect(origin: .zero, size: sz))                 // template shape
    NSGraphicsContext.current?.compositingOperation = .sourceAtop  // tint only the glyph
    NSGradient(starting: brassLight, ending: brassDark)!
        .draw(in: NSRect(origin: .zero, size: sz), angle: 90)
    out.unlockFocus()
    return out
}

func render(_ side: CGFloat) -> NSBitmapImageRep {
    let px = Int(side)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    let gctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = gctx
    let cg = gctx.cgContext

    let margin = side * 0.094
    let rect = NSRect(x: margin, y: margin, width: side - 2*margin, height: side - 2*margin)
    let plate = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.2237, yRadius: rect.width * 0.2237)

    // plate drop shadow
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -side*0.016), blur: side*0.04,
                 color: NSColor.black.withAlphaComponent(0.40).cgColor)
    plateBot.setFill(); plate.fill()
    cg.restoreGState()

    // graphite gradient plate + top sheen + faint brass ring (the dialog's badge motif)
    cg.saveGState()
    plate.addClip()
    NSGradient(starting: plateTop, ending: plateBot)!.draw(in: rect, angle: -90)
    NSGradient(colors: [NSColor.white.withAlphaComponent(0.12), NSColor.white.withAlphaComponent(0)])!
        .draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height/2), angle: -90)
    let ringD = rect.width * 0.64
    let ring = NSBezierPath(ovalIn: NSRect(x: rect.midX - ringD/2, y: rect.midY - ringD/2, width: ringD, height: ringD))
    ring.lineWidth = side * 0.013
    brass.withAlphaComponent(0.16).setStroke(); ring.stroke()
    cg.restoreGState()

    // brass key, centered + tilted, with a soft shadow for depth
    let key = brassKey(pointSize: side * 0.42)
    let ks = key.size
    cg.saveGState()
    cg.translateBy(x: side/2, y: side/2)
    cg.rotate(by: CGFloat(-32 * Double.pi / 180))
    cg.setShadow(offset: CGSize(width: 0, height: -side*0.01), blur: side*0.03,
                 color: NSColor.black.withAlphaComponent(0.55).cgColor)
    key.draw(in: NSRect(x: -ks.width/2, y: -ks.height/2, width: ks.width, height: ks.height))
    cg.restoreGState()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, _ path: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// macOS AppIcon: 16/32/128/256/512 at @1x and @2x.
let specs: [(Int, Int)] = [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]
var images: [[String: String]] = []
for (size, scale) in specs {
    let file = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
    writePNG(render(CGFloat(size * scale)), "\(outDir)/\(file)")
    images.append(["size": "\(size)x\(size)", "idiom": "mac", "filename": file, "scale": "\(scale)x"])
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try! JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: URL(fileURLWithPath: "\(outDir)/Contents.json"))
print("wrote AppIcon set (\(specs.count) sizes) to \(outDir)")
