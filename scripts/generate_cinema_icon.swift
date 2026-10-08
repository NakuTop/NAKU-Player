import AppKit
import Foundation

// A code-drawn river/play mark, independent of Kazumi's licensed mascot.
let output = CommandLine.arguments[1]
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(size) / 1024)
    scale.concat()
    NSColor(calibratedRed: 0.08, green: 0.095, blue: 0.10, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 210, yRadius: 210).fill()
    NSColor(calibratedRed: 0.90, green: 0.70, blue: 0.54, alpha: 1).setFill()
    let play = NSBezierPath()
    play.move(to: NSPoint(x: 415, y: 415))
    play.line(to: NSPoint(x: 415, y: 735))
    play.line(to: NSPoint(x: 695, y: 575))
    play.close()
    play.fill()
    NSColor(calibratedRed: 0.90, green: 0.70, blue: 0.54, alpha: 1).setStroke()
    for y: CGFloat in [260, 350] {
        let river = NSBezierPath()
        river.lineWidth = 32
        river.lineCapStyle = .round
        river.move(to: NSPoint(x: 250, y: y))
        river.curve(to: NSPoint(x: 774, y: y), controlPoint1: NSPoint(x: 420, y: y + 85), controlPoint2: NSPoint(x: 604, y: y - 85))
        river.stroke()
    }
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output).appendingPathComponent("app_icon_\(size).png"))
}
