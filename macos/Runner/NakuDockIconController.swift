import AppKit

/// Follow the application's system appearance, independently of the cinema
/// window's deliberately dark material. Never modify the signed app on disk.
final class NakuDockIconController {
    private let application: NSApplication
    private let loadImage: (String) -> NSImage?
    private let iconTheme: () -> String?
    private var preferencesObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var preferenceTimer: Timer?
    private var observation: NSKeyValueObservation?
    private var currentAsset: String?

    init(application: NSApplication = .shared,
         iconTheme: @escaping () -> String? = {
             CFPreferencesCopyValue("AppleIconAppearanceTheme" as CFString,
                 kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? String
         },
         loadImage: @escaping (String) -> NSImage? = { NSImage(named: NSImage.Name($0)) }) {
        self.application = application
        self.loadImage = loadImage
        self.iconTheme = iconTheme
        observation = application.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            guard let self = self else { return }
            if Thread.isMainThread {
                self.refresh()
            } else {
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            }
        }
        preferencesObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.refresh() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: application, queue: .main
        ) { [weak self] _ in self?.refresh() }
        // Icon style can change without an application appearance notification
        // (for example RegularDark with a light/automatic interface). A tolerant
        // low-frequency check catches changes while NAKU remains in background.
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 2
        RunLoop.main.add(timer, forMode: .common)
        preferenceTimer = timer
    }

    deinit {
        preferenceTimer?.invalidate()
        if let token = preferencesObserver { NotificationCenter.default.removeObserver(token) }
        if let token = activationObserver { NotificationCenter.default.removeObserver(token) }
    }

    static func assetName(for appearance: NSAppearance, iconTheme: String? = nil) -> String {
        switch iconTheme {
        case "RegularDark", "ClearDark", "TintedDark": return "NakuDockDark"
        case "RegularLight", "ClearLight", "TintedLight": return "NakuDockLight"
        default: break
        }
        return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? "NakuDockDark" : "NakuDockLight"
    }

    func refresh() {
        let asset = Self.assetName(for: application.effectiveAppearance, iconTheme: iconTheme())
        guard asset != currentAsset, let image = loadImage(asset) else { return }
        application.applicationIconImage = image
        application.dockTile.display()
        currentAsset = asset
    }
}
