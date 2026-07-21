// sfsymbol_export.swift
// Renders an SF Symbol to a PNG file so it can be used as a Hammerspoon icon.
//
// Compile (single-line, no SPM/Xcode, matches your usual pattern):
//   swiftc sfsymbol_export.swift -o sfsymbol-export
//
// Usage:
//   ./sfsymbol-export <symbolName> <pointSize> <outputPath> [template|white|black]
//
//   symbolName  - an SF Symbol name, e.g. "headphones", "airpods", "laptopcomputer"
//   pointSize   - the rendered point size, e.g. 18 for a menubar icon, 44 for a HUD
//   outputPath  - where to write the PNG
//   color mode  - "template" (default): keeps it as a monochrome template image,
//                 which Hammerspoon's menubar auto-tints for light/dark mode.
//                 "white" / "black": bakes in a solid color, useful when you're
//                 drawing the icon yourself (e.g. on a canvas HUD) rather than
//                 handing it to something that understands template images.

import AppKit

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
    exit(1)
}

let args = CommandLine.arguments
guard args.count >= 4 else {
    fail("Usage: sfsymbol-export <symbolName> <pointSize> <outputPath> [template|white|black]")
}

let symbolName = args[1]
let pointSize = CGFloat(Double(args[2]) ?? 18)
let outputPath = (args[3] as NSString).expandingTildeInPath
let colorMode = args.count >= 5 ? args[4] : "template"

guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) else {
    fail("SF Symbol not found: \(symbolName)")
}

let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .medium)
guard var symbolImage = base.withSymbolConfiguration(config) else {
    fail("Could not apply symbol configuration to: \(symbolName)")
}

if colorMode == "white" || colorMode == "black" {
    let tintColor: NSColor = (colorMode == "white") ? .white : .black
    let tinted = NSImage(size: symbolImage.size)
    tinted.lockFocus()
    symbolImage.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1.0)
    tintColor.set()
    NSRect(origin: .zero, size: symbolImage.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    symbolImage = tinted
    symbolImage.isTemplate = false
} else {
    symbolImage.isTemplate = true
}

// Render at 4x so the PNG stays crisp even if something upsizes it a little.
let scale: CGFloat = 4.0
let size = symbolImage.size
let pixelSize = NSSize(width: size.width * scale, height: size.height * scale)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(pixelSize.width),
    pixelsHigh: Int(pixelSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fail("Could not create bitmap representation")
}
rep.size = size

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
symbolImage.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .sourceOver, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
    fail("Could not encode PNG data")
}

do {
    try pngData.write(to: URL(fileURLWithPath: outputPath))
} catch {
    fail("Failed writing file at \(outputPath): \(error)")
}
