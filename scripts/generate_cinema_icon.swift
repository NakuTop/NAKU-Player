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
let loop = NSBezierPath()
loop.move(to: NSPoint(x: 4.3, y: 3.2))
loop.line(to: NSPoint(x: 4.3, y: 14.8))
loop.curve(to: NSPoint(x: 6.5, y: 15.3),
    controlPoint1: NSPoint(x: 4.3, y: 16.1), controlPoint2: NSPoint(x: 5.3, y: 16.0))
loop.line(to: NSPoint(x: 15.2, y: 10.3))
loop.curve(to: NSPoint(x: 15.2, y: 7.7),
    controlPoint1: NSPoint(x: 16.8, y: 9.4), controlPoint2: NSPoint(x: 16.8, y: 8.6))
loop.line(to: NSPoint(x: 6.5, y: 2.7))
loop.curve(to: NSPoint(x: 4.3, y: 3.2),
    controlPoint1: NSPoint(x: 5.3, y: 2.0), controlPoint2: NSPoint(x: 4.3, y: 1.9))
loop.close()
loop.lineWidth = 2.2
loop.lineJoinStyle = .round
NSColor.black.setStroke()
loop.stroke()
NSGraphicsContext.restoreGraphicsState()
try tray.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: trayOutput))
