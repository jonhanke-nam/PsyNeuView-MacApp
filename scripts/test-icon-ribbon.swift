#!/usr/bin/env swift
//
// Draw a TEST ribbon across every PNG of an .iconset, in place (#209).
//
//     swift scripts/test-icon-ribbon.swift <dir.iconset> [LABEL]
//
// Run by scripts/make-test-icon.sh between `iconutil -c iconset` and
// `iconutil -c icns`. AppKit rather than sips because sips cannot composite;
// a Swift script needs nothing the build machine does not already have.
//
// The ribbon is a red diagonal band across the lower-right corner with the
// label in white, sized from the image so the 16 px icon gets a plain red
// corner (text would be noise) and the 1024 px one gets readable letters.

import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 2 else {
    FileHandle.standardError.write(Data("usage: test-icon-ribbon.swift <dir.iconset> [LABEL]\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: args[1])
let label = args.count >= 3 ? args[2] : "TEST"

func stamp(_ url: URL) throws {
    guard let source = NSImage(contentsOf: url),
          let rep = source.representations.compactMap({ $0 as? NSBitmapImageRep }).first
    else { throw NSError(domain: "ribbon", code: 1, userInfo: [NSLocalizedDescriptionKey: "not a PNG: \(url.path)"]) }

    let w = rep.pixelsWide
    let h = rep.pixelsHigh
    guard let out = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { throw NSError(domain: "ribbon", code: 2) }
    // Pixel-for-pixel: the iconset's @2x files are the same image at twice
    // the pixels, and the ribbon must scale with the pixels, not the points.
    out.size = NSSize(width: w, height: h)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: out) else { throw NSError(domain: "ribbon", code: 3) }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high

    let frame = NSRect(x: 0, y: 0, width: w, height: h)
    rep.draw(in: frame)

    let side = CGFloat(min(w, h))
    // The band: a rotated rectangle through the lower-right corner, clipped
    // to the icon's own alpha so a rounded icon keeps its rounded corner.
    let bandWidth = side * 0.19
    let center = CGPoint(x: side * 0.76, y: side * 0.24)

    let mask = NSBezierPath()
    mask.appendRect(frame)
    NSGraphicsContext.current?.cgContext.saveGState()
    // Clip to where the original icon is opaque enough to be seen.
    let cg = NSGraphicsContext.current!.cgContext
    if let image = rep.cgImage {
        cg.clip(to: frame, mask: image)
    }

    let transform = NSAffineTransform()
    transform.translateX(by: center.x, yBy: center.y)
    transform.rotate(byDegrees: 45)
    transform.concat()

    let band = NSRect(x: -side, y: -bandWidth / 2, width: side * 2, height: bandWidth)
    NSColor(calibratedRed: 0.86, green: 0.13, blue: 0.13, alpha: 0.95).setFill()
    band.fill()
    NSColor(calibratedWhite: 1, alpha: 0.85).setFill()
    NSRect(x: -side, y: bandWidth / 2 - side * 0.012, width: side * 2, height: side * 0.012).fill()
    NSRect(x: -side, y: -bandWidth / 2, width: side * 2, height: side * 0.012).fill()

    // Letters only when they can be read: at 32 px and under the band alone
    // is the mark.
    if side >= 48 {
        let fontSize = bandWidth * 0.62
        let font = NSFont.systemFont(ofSize: fontSize, weight: .heavy)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .kern: fontSize * 0.08,
        ]
        let text = NSAttributedString(string: label, attributes: attributes)
        let size = text.size()
        text.draw(at: NSPoint(x: -size.width / 2, y: -size.height / 2 + fontSize * 0.04))
    }
    cg.restoreGState()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = out.representation(using: .png, properties: [:]) else { throw NSError(domain: "ribbon", code: 4) }
    try png.write(to: url, options: .atomic)
}

let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
let pngs = files.filter { $0.pathExtension.lowercased() == "png" }
guard !pngs.isEmpty else {
    FileHandle.standardError.write(Data("no PNGs in \(directory.path)\n".utf8))
    exit(1)
}
for url in pngs {
    do {
        try stamp(url)
    } catch {
        FileHandle.standardError.write(Data("\(url.lastPathComponent): \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
print("  ✓ \(label) ribbon on \(pngs.count) images in \(directory.lastPathComponent)")
