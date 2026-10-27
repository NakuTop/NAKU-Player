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
        let aqua = NSAppearance(named: .aqua)!
        let night = NSAppearance(named: .darkAqua)!
        for theme in ["RegularDark", "ClearDark", "TintedDark"] {
            precondition(NakuDockIconController.assetName(for: aqua, iconTheme: theme) == "NakuDockDark")
        }
        for theme in ["RegularLight", "ClearLight", "TintedLight"] {
            precondition(NakuDockIconController.assetName(for: night, iconTheme: theme) == "NakuDockLight")
        }
        for theme in ["RegularAutomatic", "ClearAutomatic", "TintedAutomatic", "unknown"] {
            precondition(NakuDockIconController.assetName(for: aqua, iconTheme: theme) == "NakuDockLight")
            precondition(NakuDockIconController.assetName(for: night, iconTheme: theme) == "NakuDockDark")
        }
        let light = solid(.red)
        let dark = solid(.blue)
        var requested: [String] = []
        app.appearance = NSAppearance(named: .aqua)
        let controller = NakuDockIconController(application: app, iconTheme: { nil }) { name in
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
        // Reproduce the user's independent dark-icon/light-interface setting.
        app.appearance = aqua
        var theme = "RegularDark"
        let independent = NakuDockIconController(application: app, iconTheme: { theme }) { $0 == "NakuDockDark" ? dark : light }
        precondition(isBlue(app.applicationIconImage))
        theme = "RegularLight"
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        precondition(!isBlue(app.applicationIconImage))
        withExtendedLifetime(independent) {}
        print("PASS: light/dark/high-contrast mapping, actual AppKit appearance observation and Dock image replacement; no repeated reload; independent icon style overrides interface and updates on preference notification")
    }
}
