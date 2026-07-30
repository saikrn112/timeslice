#!/usr/bin/env swift
// Generates Timeslice.icns: a clock face "sliced through" by a diagonal cut, with the two
// halves offset slightly — evokes time being split, without looking like a pie chart.
// Usage: swift scripts/make_icon.swift  → writes scripts/AppIcon.iconset + scripts/Timeslice.icns

import AppKit

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size

    // Background: rounded-rect gradient tile (macOS-style app icon).
    let inset = s * 0.06
    let rect = CGRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    let bgPath = CGPath(roundedRect: rect, cornerWidth: s*0.22, cornerHeight: s*0.22, transform: nil)
    ctx.addPath(bgPath)
    ctx.clip()
    let colors = [NSColor(calibratedRed: 0.20, green: 0.44, blue: 0.86, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.36, green: 0.24, blue: 0.78, alpha: 1).cgColor]
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: s), end: CGPoint(x: s, y: 0), options: [])

    let center = CGPoint(x: s/2, y: s/2)
    let radius = s * 0.28

    // The diagonal "slice": split the clock into two halves offset perpendicular to the cut.
    let angle = CGFloat.pi / 5          // slice direction
    let offset = s * 0.018              // how far the halves separate
    let dx = cos(angle + .pi/2) * offset
    let dy = sin(angle + .pi/2) * offset

    func clockFace(shift: CGPoint, half: Int) {
        ctx.saveGState()
        // Clip to one half-plane along the slice line through center.
        let big = s * 2
        let along = CGPoint(x: cos(angle), y: sin(angle))
        let normal = CGPoint(x: cos(angle + .pi/2), y: sin(angle + .pi/2)) // points to half 1
        let sgn: CGFloat = half == 0 ? 1 : -1
        let p0 = CGPoint(x: center.x + along.x*big + normal.x*sgn*big,
                         y: center.y + along.y*big + normal.y*sgn*big)
        let p1 = CGPoint(x: center.x - along.x*big + normal.x*sgn*big,
                         y: center.y - along.y*big + normal.y*sgn*big)
        let p2 = CGPoint(x: center.x - along.x*big, y: center.y - along.y*big)
        let p3 = CGPoint(x: center.x + along.x*big, y: center.y + along.y*big)
        ctx.beginPath()
        ctx.move(to: p0); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.addLine(to: p3); ctx.closePath()
        ctx.clip()

        let c = CGPoint(x: center.x + shift.x, y: center.y + shift.y)

        // White dial.
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillEllipse(in: CGRect(x: c.x - radius, y: c.y - radius, width: radius*2, height: radius*2))

        // Tick marks.
        ctx.setStrokeColor(NSColor(calibratedWhite: 0.25, alpha: 1).cgColor)
        ctx.setLineWidth(max(1, s*0.006))
        for i in 0..<12 {
            let a = CGFloat(i) / 12 * 2 * .pi
            let r1 = radius * 0.82, r2 = radius * 0.92
            ctx.move(to: CGPoint(x: c.x + cos(a)*r1, y: c.y + sin(a)*r1))
            ctx.addLine(to: CGPoint(x: c.x + cos(a)*r2, y: c.y + sin(a)*r2))
        }
        ctx.strokePath()

        // Hands.
        ctx.setStrokeColor(NSColor(calibratedRed: 0.20, green: 0.44, blue: 0.86, alpha: 1).cgColor)
        ctx.setLineCap(.round)
        ctx.setLineWidth(max(1.5, s*0.016))
        ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x, y: c.y + radius*0.55)); ctx.strokePath()       // minute
        ctx.setLineWidth(max(1.5, s*0.02))
        ctx.move(to: c); ctx.addLine(to: CGPoint(x: c.x + radius*0.4, y: c.y + radius*0.15)); ctx.strokePath() // hour
        ctx.restoreGState()
    }

    clockFace(shift: CGPoint(x: dx, y: dy), half: 0)
    clockFace(shift: CGPoint(x: -dx, y: -dy), half: 1)

    // The slice line itself (subtle dark gap).
    ctx.setStrokeColor(NSColor(calibratedWhite: 0, alpha: 0.28).cgColor)
    ctx.setLineWidth(max(1, s*0.012))
    let along = CGPoint(x: cos(angle), y: sin(angle))
    ctx.move(to: CGPoint(x: center.x - along.x*radius*1.3, y: center.y - along.y*radius*1.3))
    ctx.addLine(to: CGPoint(x: center.x + along.x*radius*1.3, y: center.y + along.y*radius*1.3))
    ctx.strokePath()

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, _ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                              bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                              colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let here = URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
let scriptsDir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("scripts")
let iconset = scriptsDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
    let img = drawIcon(size: CGFloat(px))
    try! png(img, px).write(to: iconset.appendingPathComponent("\(name).png"))
}
print("Wrote \(iconset.path)")
