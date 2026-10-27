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
