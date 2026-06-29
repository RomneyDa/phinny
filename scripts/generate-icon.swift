#!/usr/bin/env swift
// Generates Phinny's macOS app icon set procedurally (no binary art checked in).
// Draws a rounded-square indigo-to-violet gradient with a white koi (kohaku
// pattern, orange spots) swimming diagonally upward over faint pond ripples,
// then writes every required size into the .appiconset.
//
// Run:  swift scripts/generate-icon.swift
import AppKit

// Tuple-based bezier helpers so the koi can be hand-plotted in local coordinates.
extension NSBezierPath {
    func m(_ p: (CGFloat, CGFloat)) { move(to: NSPoint(x: p.0, y: p.1)) }
    func l(_ p: (CGFloat, CGFloat)) { line(to: NSPoint(x: p.0, y: p.1)) }
    func c(_ p: (CGFloat, CGFloat), _ a: (CGFloat, CGFloat), _ b: (CGFloat, CGFloat)) {
        curve(to: NSPoint(x: p.0, y: p.1),
              controlPoint1: NSPoint(x: a.0, y: a.1),
              controlPoint2: NSPoint(x: b.0, y: b.1))
    }
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let outDir = "Resources/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func draw(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // Transparent background: the koi is the whole icon. Plotted in a local
    // space (body length along +x, snout to the right), then rotated to swim
    // diagonally upward - a "rising" pose that nods to growth.
    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let t = NSAffineTransform()
    t.translateX(by: rect.midX, yBy: rect.midY - rect.height * 0.02)
    t.rotate(byDegrees: 26)
    let koiScale = s * 0.66
    t.scaleX(by: koiScale, yBy: koiScale)
    func place(_ path: NSBezierPath) -> NSBezierPath { t.transform(path) }

    // Sleek body: arched back, fuller belly, tapering to a slender peduncle.
    let body = NSBezierPath()
    body.m((0.66, 0.0))
    body.c((0.0, 0.21), (0.44, 0.15), (0.20, 0.21))
    body.c((-0.42, 0.05), (-0.24, 0.18), (-0.34, 0.10))
    body.c((-0.43, -0.04), (-0.47, 0.02), (-0.47, -0.01))
    body.c((0.0, -0.22), (-0.32, -0.11), (-0.20, -0.22))
    body.c((0.66, 0.0), (0.22, -0.22), (0.46, -0.15))
    body.close()

    // Graceful forked tail with broad lobes and a soft central notch.
    let tail = NSBezierPath()
    tail.m((-0.40, 0.04))
    tail.c((-0.88, 0.28), (-0.58, 0.12), (-0.80, 0.26))
    tail.c((-0.62, 0.0), (-0.80, 0.10), (-0.68, 0.03))
    tail.c((-0.88, -0.28), (-0.68, -0.03), (-0.80, -0.10))
    tail.c((-0.40, -0.04), (-0.80, -0.26), (-0.58, -0.12))
    tail.close()

    // Long, low dorsal sail (base hidden under the body).
    let dorsal = NSBezierPath()
    dorsal.m((0.24, 0.16))
    dorsal.c((-0.24, 0.10), (0.06, 0.33), (-0.16, 0.30))
    dorsal.l((0.24, 0.16))
    dorsal.close()

    // Near-side pectoral fin sweeping down from behind the head.
    let pec = NSBezierPath()
    pec.m((0.34, -0.07))
    pec.c((0.12, -0.34), (0.30, -0.24), (0.20, -0.34))
    pec.c((0.34, -0.07), (0.14, -0.19), (0.30, -0.11))
    pec.close()

    let placedBody = place(body)

    // A soft shadow gives the white koi some presence on light backgrounds.
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
    shadow.shadowBlurRadius = s * 0.014
    shadow.shadowOffset = NSSize(width: 0, height: -s * 0.006)

    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    // Tail and dorsal sit behind the body.
    NSColor.white.withAlphaComponent(0.96).setFill()
    place(tail).fill()
    place(dorsal).fill()
    place(pec).fill()
    // White body on top.
    NSColor.white.setFill()
    placedBody.fill()
    NSGraphicsContext.restoreGraphicsState()

    // Kohaku pattern: separate red patches (not one blob), clipped to the body.
    NSGraphicsContext.saveGraphicsState()
    placedBody.addClip()
    let kohaku = NSColor(srgbRed: 0.91, green: 0.30, blue: 0.11, alpha: 1)
    let spots: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (0.38, 0.05, 0.15, 0.12),   // head cap
        (0.04, 0.06, 0.18, 0.13),   // mid-back
        (-0.26, 0.0, 0.12, 0.10),   // rear
    ]
    kohaku.setFill()
    for (cx, cy, rx, ry) in spots {
        place(NSBezierPath(ovalIn: NSRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))).fill()
    }
    NSGraphicsContext.restoreGraphicsState()

    // Eye, kept on white so it always reads.
    let ink = NSColor(srgbRed: 0.15, green: 0.13, blue: 0.28, alpha: 1)
    let eyeR: CGFloat = 0.032
    ink.setFill()
    place(NSBezierPath(ovalIn: NSRect(x: 0.50 - eyeR, y: 0.085 - eyeR, width: eyeR * 2, height: eyeR * 2))).fill()

    // Barbels (whiskers) at the mouth.
    let barbels = NSBezierPath()
    barbels.m((0.64, -0.01)); barbels.c((0.76, -0.10), (0.69, -0.04), (0.74, -0.08))
    barbels.m((0.64, 0.02)); barbels.c((0.78, -0.03), (0.70, 0.01), (0.75, -0.01))
    let placedBarbels = place(barbels)
    placedBarbels.lineWidth = s * 0.008
    placedBarbels.lineCapStyle = .round
    ink.withAlphaComponent(0.7).setStroke()
    placedBarbels.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to name: String) {
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}

// Render unique pixel sizes once, reuse for @1x/@2x slots.
var files: [Int: String] = [:]
for size in sizes {
    let name = "icon_\(size).png"
    write(draw(size: size), to: name)
    files[size] = name
}

// macOS app icon set: 16,32,128,256,512 each at @1x and @2x.
struct Slot { let size: Int; let scale: Int; let px: Int }
let slots = [
    Slot(size: 16, scale: 1, px: 16), Slot(size: 16, scale: 2, px: 32),
    Slot(size: 32, scale: 1, px: 32), Slot(size: 32, scale: 2, px: 64),
    Slot(size: 128, scale: 1, px: 128), Slot(size: 128, scale: 2, px: 256),
    Slot(size: 256, scale: 1, px: 256), Slot(size: 256, scale: 2, px: 512),
    Slot(size: 512, scale: 1, px: 512), Slot(size: 512, scale: 2, px: 1024),
]
let images = slots.map { slot in
    """
        {
          "filename" : "\(files[slot.px]!)",
          "idiom" : "mac",
          "scale" : "\(slot.scale)x",
          "size" : "\(slot.size)x\(slot.size)"
        }
    """
}.joined(separator: ",\n")

let contents = """
{
  "images" : [
\(images)
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
"""
try? contents.write(toFile: "\(outDir)/Contents.json", atomically: true, encoding: .utf8)
print("Wrote app icon set to \(outDir)")
