import AppKit

@main
struct DockIconCheck {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        for name in [NSAppearance.Name.aqua, .accessibilityHighContrastAqua] {
            precondition(NakuDockIconController.assetName(for: NSAppearance(named: name)!) == "NakuDockLight")
        }
        for name in [NSAppearance.Name.darkAqua, .accessibilityHighContrastDarkAqua] {
            precondition(NakuDockIconController.assetName(for: NSAppearance(named: name)!) == "NakuDockDark")
        }
        func solid(_ color: NSColor) -> NSImage {
            NSImage(size: NSSize(width: 128, height: 128), flipped: false) { rect in
                color.setFill(); rect.fill(); return true
            }
        }
        func isBlue(_ image: NSImage?) -> Bool {
            let bitmap = NSBitmapImageRep(data: image!.tiffRepresentation!)!
            return bitmap.colorAt(x: 64, y: 64)!.usingColorSpace(.deviceRGB)!.blueComponent > 0.8
        }
        let light = solid(.red)
        let dark = solid(.blue)
        var requested: [String] = []
        app.appearance = NSAppearance(named: .aqua)
        let controller = NakuDockIconController(application: app) { name in
            requested.append(name)
            return name == "NakuDockDark" ? dark : light
        }
        precondition(!isBlue(app.applicationIconImage))
        app.appearance = NSAppearance(named: .darkAqua)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(isBlue(app.applicationIconImage))
        app.appearance = NSAppearance(named: .aqua)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        precondition(!isBlue(app.applicationIconImage))
        controller.refresh()
        precondition(requested == ["NakuDockLight", "NakuDockDark", "NakuDockLight"])
        print("PASS: light/dark/high-contrast mapping, actual AppKit appearance observation and Dock image replacement; no repeated reload")
    }
}
