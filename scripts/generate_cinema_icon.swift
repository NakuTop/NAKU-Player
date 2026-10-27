import AppKit
import Foundation

// Package the canonical NAKU cinema artwork; preserve its transparent margins.
// Usage: swift scripts/generate_cinema_icon.swift OUTPUT [SOURCE_PNG]
let arguments = CommandLine.arguments
guard arguments.count >= 2 else { fatalError("Expected output iconset directory") }
let output = URL(fileURLWithPath: arguments[1], isDirectory: true)
let source = arguments.count > 2 ? arguments[2] : "assets/images/logo/naku_cinema_icon.png"
guard let image = NSImage(contentsOfFile: source) else { fatalError("Missing cinema artwork") }
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    try data.write(to: output.appendingPathComponent("app_icon_\(size).png"))
}

// Native menu-bar variant: the same soft playback loop, reduced to a template
// silhouette. AppKit supplies the correct light/dark and selected-state tint.
let trayOutput = arguments.count > 3 ? arguments[3] : "assets/images/logo/naku_tray_template.png"
let tray = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: tray)!
let trayScale = NSAffineTransform()
trayScale.scale(by: 2)
trayScale.concat()
// Compact rounded N keeps the app mark recognizable at native 18pt size.
let mark = NSBezierPath()
mark.move(to: NSPoint(x: 4.6, y: 4.1))
mark.line(to: NSPoint(x: 4.6, y: 13.9))
mark.line(to: NSPoint(x: 13.4, y: 4.1))
mark.line(to: NSPoint(x: 13.4, y: 13.9))
mark.lineWidth = 3.3
mark.lineCapStyle = .round
mark.lineJoinStyle = .round
NSColor.black.setStroke()
mark.stroke()
NSGraphicsContext.restoreGraphicsState()
try tray.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: trayOutput))
