import Cocoa
import FlutterMacOS
import window_manager
import CFNetwork
import Sparkle

// FlutterView accepts the first mouse event even when its window is inactive.
// This view lets AppKit activate the window without forwarding that event.
private final class InactiveMouseBlockerView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard window?.isKeyWindow == false else {
      return nil
    }
    return super.hitTest(point)
  }

  override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
    return false
  }
}

class MainFlutterWindow: NSWindow {
  private let inactiveMouseBlocker = InactiveMouseBlockerView()
  private var glassBackdrop: NSVisualEffectView?
  private var updaterController: SPUStandardUpdaterController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.backgroundColor = NSColor.clear
    self.isOpaque = false
    flutterViewController.backgroundColor = NSColor.clear
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    if let contentView = self.contentView {
      inactiveMouseBlocker.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(
        inactiveMouseBlocker,
        positioned: .above,
        relativeTo: nil
      )
      NSLayoutConstraint.activate([
        inactiveMouseBlocker.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
        inactiveMouseBlocker.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        inactiveMouseBlocker.topAnchor.constraint(equalTo: contentView.topAnchor),
        inactiveMouseBlocker.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
      ])
    }

    if let flutterView = self.contentView, let frameView = flutterView.superview {
      let backdrop = NSVisualEffectView(frame: flutterView.frame)
      backdrop.material = .hudWindow
      backdrop.blendingMode = .behindWindow
      backdrop.state = .active
      backdrop.autoresizingMask = [.width, .height]
      frameView.addSubview(backdrop, positioned: .below, relativeTo: flutterView)
      glassBackdrop = backdrop
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    let networkChannel = FlutterMethodChannel(
      name: "yingchuan/network",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    networkChannel.setMethodCallHandler { call, result in
      guard call.method == "systemProxy" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let settings = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [String: Any] ?? [:]
      let keys = ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
                  "ExceptionsList", "ExcludeSimpleHostnames", "ProxyAutoConfigEnable"]
      var snapshot: [String: Any] = [:]
      for key in keys { if let value = settings[key] { snapshot[key] = value } }
      result(snapshot)
    }

    // Keep one native controller alive for the window lifetime. Sparkle owns its
    // persisted preferences, signature validation, scheduler, and installer UI.
    let updater = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    updaterController = updater
    let updateChannel = FlutterMethodChannel(
      name: "naku/updater", binaryMessenger: flutterViewController.engine.binaryMessenger)
    updateChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "state":
        result([
          "automaticChecks": updater.updater.automaticallyChecksForUpdates,
          "automaticDownloads": updater.updater.automaticallyDownloadsUpdates,
          "canCheck": updater.updater.canCheckForUpdates,
          "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
          "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
        ])
      case "check":
        guard updater.updater.canCheckForUpdates else {
          result(FlutterError(code: "busy", message: "更新检查正在进行，请查看更新窗口。", details: nil))
          return
        }
        updater.checkForUpdates(nil)
        result(nil)
      case "configure":
        guard let args = call.arguments as? [String: Bool] else {
          result(FlutterError(code: "arguments", message: "无效的更新设置", details: nil))
          return
        }
        if let enabled = args["automaticChecks"] {
          updater.updater.automaticallyChecksForUpdates = enabled
        }
        if let enabled = args["automaticDownloads"] {
          updater.updater.automaticallyDownloadsUpdates = enabled
        }
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    if let appMenu = NSApp.mainMenu?.items.first?.submenu {
      let item = NSMenuItem(title: "检查更新…",
        action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
      item.target = updater
      appMenu.insertItem(item, at: min(2, appMenu.items.count))
    }

    super.awakeFromNib()
  }

  override public func order(_ place: NSWindow.OrderingMode, relativeTo otherWin: Int) {
    super.order(place, relativeTo: otherWin)
    hiddenWindowAtLaunch()
  }
}
