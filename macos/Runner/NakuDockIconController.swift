import AppKit

/// Follow the application's system appearance, independently of the cinema
/// window's deliberately dark material. Never modify the signed app on disk.
final class NakuDockIconController {
    private let application: NSApplication
    private let loadImage: (String) -> NSImage?
    private var observation: NSKeyValueObservation?
    private var currentAsset: String?

    init(application: NSApplication = .shared,
         loadImage: @escaping (String) -> NSImage? = { NSImage(named: NSImage.Name($0)) }) {
        self.application = application
        self.loadImage = loadImage
        observation = application.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            guard let self = self else { return }
            if Thread.isMainThread {
                self.refresh()
            } else {
                DispatchQueue.main.async { [weak self] in self?.refresh() }
            }
        }
    }

    static func assetName(for appearance: NSAppearance) -> String {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? "NakuDockDark" : "NakuDockLight"
    }

    func refresh() {
        let asset = Self.assetName(for: application.effectiveAppearance)
        guard asset != currentAsset, let image = loadImage(asset) else { return }
        application.applicationIconImage = image
        application.dockTile.display()
        currentAsset = asset
    }
}
