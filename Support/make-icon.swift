#!/usr/bin/env swift
//
// Draws the Imark app icon and writes Support/AppIcon.icns.
//
//   swift Support/make-icon.swift
//
// The mark is a half-disc: flat on the left, a true semicircle on the right.
// Drawn rather than exported so every size is rendered at its own resolution
// and stays crisp at 16px instead of being downsampled into mush.

import AppKit

// Off-white on near-black. Plain white on pure black is harsher than it looks
// at 1024px, and reads as a hole in the Dock at 16px.
let accent = NSColor(srgbRed: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1)
let background = NSColor(srgbRed: 0x13 / 255, green: 0x13 / 255, blue: 0x16 / 255, alpha: 1)

/// Fractions of the canvas. They are not constant across sizes: a mark that
/// looks right at 512px is too timid at 16px, where there is no room for
/// padding. Small sizes get a bigger mark and a tighter squircle margin — the
/// same trick Apple's own icons use rather than scaling one drawing down.
struct Metric {
    let squircleInset: CGFloat
    let markHeight: CGFloat
    let flatCorner: CGFloat      // rounding on the two corners of the flat edge

    static let cornerRatio: CGFloat = 0.2237   // macOS squircle, near enough
    static let aspect: CGFloat = 0.62          // width as a fraction of height

    static func forSize(_ size: CGFloat) -> Metric {
        if size <= 32 {
            return Metric(squircleInset: 0.055, markHeight: 0.60, flatCorner: 0.06)
        }
        if size <= 64 {
            return Metric(squircleInset: 0.075, markHeight: 0.53, flatCorner: 0.08)
        }
        return Metric(squircleInset: 0.098, markHeight: 0.46, flatCorner: 0.10)
    }
}

func halfDisc(in rect: NSRect, flatCorner: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let radius = rect.height / 2
    let corner = min(flatCorner, radius)

    let left = rect.minX
    let right = rect.maxX
    let bottom = rect.minY
    let top = rect.maxY
    let arcCentre = NSPoint(x: right - radius, y: bottom + radius)

    path.move(to: NSPoint(x: left + corner, y: bottom))
    path.line(to: NSPoint(x: arcCentre.x, y: bottom))
    // The whole right side is one semicircle, bottom to top.
    path.appendArc(withCenter: arcCentre, radius: radius, startAngle: -90, endAngle: 90)
    path.line(to: NSPoint(x: left + corner, y: top))
    path.appendArc(
        from: NSPoint(x: left, y: top),
        to: NSPoint(x: left, y: bottom),
        radius: corner
    )
    path.appendArc(
        from: NSPoint(x: left, y: bottom),
        to: NSPoint(x: right, y: bottom),
        radius: corner
    )
    path.close()
    return path
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

    let m = Metric.forSize(size)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    let inset = size * m.squircleInset
    let plate = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    background.setFill()
    NSBezierPath(
        roundedRect: plate,
        xRadius: plate.width * Metric.cornerRatio,
        yRadius: plate.width * Metric.cornerRatio
    ).fill()

    let height = size * m.markHeight
    let width = height * Metric.aspect
    // Optically centred, not mathematically: the mass sits to the right of the
    // flat edge, so the shape has to sit a little left of centre to look level.
    let mark = NSRect(
        x: (size - width) / 2 - size * 0.012,
        y: (size - height) / 2,
        width: width,
        height: height
    )

    accent.setFill()
    halfDisc(in: mark, flatCorner: size * m.flatCorner * 0.5).fill()

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
