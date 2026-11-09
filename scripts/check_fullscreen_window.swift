import Cocoa

@main
struct FullscreenWindowCheck {
  static func main() {
    _ = NSApplication.shared
    let window = NakuFullscreenWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 700),
      styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    window.enableNativeFullscreen()
    precondition(window.collectionBehavior.contains(.fullScreenPrimary))
    let original = window.frame
    window.level = .floating
    window.aspectRatio = NSSize(width: 16, height: 9)
    window.setFrame(NSRect(x: 80, y: 80, width: 480, height: 270), display: false)
    window.prepareForNativeFullscreen()
    precondition(window.level == .normal)
    precondition(window.aspectRatio == .zero && window.contentAspectRatio == .zero)
    precondition(window.frame.width == original.width && window.frame.height == original.height)
    precondition(window.collectionBehavior.contains(.fullScreenPrimary))
    print("PASS: PiP fullscreen restores normal level, size and unconstrained aspect; green button remains fullscreen primary")
    window.level = .floating
    window.level = .normal
    window.setFrame(NSRect(x: 100, y: 100, width: 900, height: 650), display: false)
    let restored = window.frame
    window.prepareForNativeFullscreen()
    precondition(window.frame == restored)
    print("PASS: an ordinary PiP exit clears the old snapshot; normal fullscreen preserves current geometry")
  }
}
