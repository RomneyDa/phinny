#!/usr/bin/env swift
// Generates Phinny's macOS app icon set procedurally (no binary art checked in).
// Draws a rounded-square indigo→violet gradient with a white ascending bar
// chart + trend dot, then writes every required size into the .appiconset.
//
// Run:  swift scripts/generate-icon.swift
import AppKit

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

    // macOS icons sit inside the canvas with ~10% padding around a squircle.
    let pad = s * 0.10
    let rect = NSRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
    let radius = rect.width * 0.2237
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    shape.addClip()

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.39, green: 0.40, blue: 0.95, alpha: 1),
        NSColor(srgbRed: 0.62, green: 0.36, blue: 0.96, alpha: 1),
    ])!
    gradient.draw(in: rect, angle: -55)

    // Ascending bars.
    let white = NSColor.white
    let heights: [CGFloat] = [0.30, 0.48, 0.66, 0.86]
    let area = rect.insetBy(dx: rect.width * 0.20, dy: rect.height * 0.20)
    let gap = area.width * 0.07
    let barW = (area.width - gap * CGFloat(heights.count - 1)) / CGFloat(heights.count)
    let barRadius = barW * 0.28
    for (i, h) in heights.enumerated() {
        let x = area.minX + CGFloat(i) * (barW + gap)
        let barH = area.height * h
        let r = NSRect(x: x, y: area.minY, width: barW, height: barH)
        white.withAlphaComponent(0.92).setFill()
        NSBezierPath(roundedRect: r, xRadius: barRadius, yRadius: barRadius).fill()
    }

    // Trend dot on the tallest bar.
    let dotD = area.width * 0.12
    let lastX = area.minX + CGFloat(heights.count - 1) * (barW + gap) + barW / 2
    let dot = NSRect(
        x: lastX - dotD / 2,
        y: area.minY + area.height * heights.last! - dotD / 2,
        width: dotD, height: dotD
    )
    white.setFill()
    NSBezierPath(ovalIn: dot).fill()

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
