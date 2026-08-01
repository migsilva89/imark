#!/usr/bin/env swift
//
// Draws the Imark app icon and writes Support/AppIcon.icns.
//
//   swift Support/make-icon.swift
//
// The symbol follows the rules in docs/DESIGN.md: a lowercase "i" taken apart
// into three solid shapes — circle, even-width stem, and a baseline bar. Drawn
// rather than exported so every size is rendered at its own resolution and
// stays crisp at 16px instead of being downsampled into mush.

import AppKit

let accent = NSColor(srgbRed: 0x7A / 255, green: 0x6B / 255, blue: 0xD8 / 255, alpha: 1)
let background = NSColor(srgbRed: 0x1E / 255, green: 0x1E / 255, blue: 0x22 / 255, alpha: 1)

/// All measurements are fractions of the canvas, so the geometry is identical
/// at every size.
enum Metric {
    static let squircleInset = 0.098
    static let cornerRatio = 0.2237      // macOS squircle, near enough
    static let stem = 0.0605
    static let circle = 0.0968           // 1.6 × stem
    static let gap = 0.045
    static let baselineWidth = 0.293
    static let groupHeight = 0.42
    static let opticalLift = 0.012       // the baseline is bottom-heavy
}

func drawIcon(size: CGFloat) -> NSBitmapImageRep {
    let pixels = Int(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    // AppKit draws from the bottom-left; the layout below reads top-down.
    func fromTop(_ y: CGFloat, _ height: CGFloat) -> CGFloat { size - y - height }

    let inset = size * Metric.squircleInset
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    background.setFill()
    NSBezierPath(
        roundedRect: plate,
        xRadius: plate.width * Metric.cornerRatio,
        yRadius: plate.width * Metric.cornerRatio
    ).fill()

    let stem = size * Metric.stem
    let circle = size * Metric.circle
    let gap = size * Metric.gap
    let baselineWidth = size * Metric.baselineWidth
    let baselineHeight = stem
    let stemHeight = size * Metric.groupHeight - circle - baselineHeight - gap * 2

    var top = (size - size * Metric.groupHeight) / 2 - size * Metric.opticalLift
    let centre = size / 2

    accent.setFill()

    NSBezierPath(ovalIn: NSRect(
        x: centre - circle / 2,
        y: fromTop(top, circle),
        width: circle,
        height: circle
    )).fill()
    top += circle + gap

    NSBezierPath(
        roundedRect: NSRect(x: centre - stem / 2, y: fromTop(top, stemHeight), width: stem, height: stemHeight),
        xRadius: stem / 2,
        yRadius: stem / 2
    ).fill()
    top += stemHeight + gap

    NSBezierPath(
        roundedRect: NSRect(
            x: centre - baselineWidth / 2,
            y: fromTop(top, baselineHeight),
            width: baselineWidth,
            height: baselineHeight
        ),
        xRadius: baselineHeight / 2,
        yRadius: baselineHeight / 2
    ).fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// MARK: - Write the iconset

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("Support/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(name: String, size: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let rep = drawIcon(size: variant.size)
    guard let png = rep.representation(using: .png, properties: [:]) else { continue }
    try png.write(to: iconset.appendingPathComponent("\(variant.name).png"))
}

let convert = Process()
convert.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
convert.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Support/AppIcon.icns").path]
try convert.run()
convert.waitUntilExit()

try? FileManager.default.removeItem(at: iconset)
print(convert.terminationStatus == 0 ? "Support/AppIcon.icns" : "iconutil falhou")
