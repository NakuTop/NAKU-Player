import Cocoa
import FlutterMacOS
import window_manager
import CFNetwork
import Sparkle

// Decoration must never become the target of a mouse event. Flutter handles
// activation clicks itself, including when the app has just regained focus.
private final class PassiveVisualEffectView: NSVisualEffectView {
  override func hitTest(_ point: NSPoint) -> NSView? {
    return nil
  }
}

// Own both views through public AppKit containment. Window style and fullscreen
// changes can rebuild AppKit's private frame view, so nothing is attached there.
private final class GlassContentViewController: NSViewController {
  let flutterViewController: FlutterViewController
  private let backdrop = PassiveVisualEffectView(frame: .zero)
  private var accessibilityObserver: NSObjectProtocol?
  var onAccessibilityChange: (([String: Bool]) -> Void)?

  var accessibilityState: [String: Bool] {
    [
      "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
      "reduceMotion": NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
    ]
  }

  deinit {
    if let observer = accessibilityObserver {
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  private func updateAccessibilityAppearance() {
    let state = accessibilityState
    // Keep the material stable when another window becomes key, while honoring
    // the system accessibility override with a genuinely opaque fallback.
    backdrop.isHidden = state["reduceTransparency"] == true
    view.layer?.backgroundColor = state["reduceTransparency"] == true
      ? NSColor(srgbRed: 9.0 / 255.0, green: 9.0 / 255.0, blue: 11.0 / 255.0, alpha: 1).cgColor
      : NSColor.clear.cgColor
    onAccessibilityChange?(state)
  }

  init(flutterViewController: FlutterViewController) {
    self.flutterViewController = flutterViewController
    super.init(nibName: nil, bundle: nil)
    addChild(flutterViewController)
  }

  required init?(coder: NSCoder) {
    fatalError("GlassContentViewController is created programmatically")
  }

  override func loadView() {
    let container = NSView(frame: .zero)
    container.appearance = NSAppearance(named: .darkAqua)
    container.wantsLayer = true
    self.view = container

    backdrop.material = .hudWindow
    backdrop.blendingMode = .behindWindow
    backdrop.state = .active
    backdrop.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(backdrop)

    let flutterView = flutterViewController.view
    flutterView.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(flutterView, positioned: .above, relativeTo: backdrop)

    NSLayoutConstraint.activate([
      backdrop.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      backdrop.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      backdrop.topAnchor.constraint(equalTo: container.topAnchor),
      backdrop.bottomAnchor.constraint(equalTo: container.bottomAnchor),
      flutterView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      flutterView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      flutterView.topAnchor.constraint(equalTo: container.topAnchor),
      flutterView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])
    updateAccessibilityAppearance()
    accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main
    ) { [weak self] _ in
      self?.updateAccessibilityAppearance()
    }
  }
}

class MainFlutterWindow: NSWindow {
  // Keep the engine owner explicit; the window's root controller is the glass
  // container, while all plugin registrars still belong to this Flutter child.
  private(set) var flutterViewController: FlutterViewController?
  private var updaterController: SPUStandardUpdaterController?

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.backgroundColor = NSColor.clear
    self.isOpaque = false
    flutterViewController.backgroundColor = NSColor.clear
    self.flutterViewController = flutterViewController
    let windowFrame = self.frame
    let glassController = GlassContentViewController(
      flutterViewController: flutterViewController)
    self.contentViewController = glassController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    let appearanceChannel = FlutterMethodChannel(
      name: "naku/appearance", binaryMessenger: flutterViewController.engine.binaryMessenger)
    appearanceChannel.setMethodCallHandler { [weak glassController] call, result in
      guard call.method == "state" else {
        result(FlutterMethodNotImplemented)
        return
      }
      result(glassController?.accessibilityState ?? [:])
    }
    glassController.onAccessibilityChange = { [weak self] state in
      let reduced = state["reduceTransparency"] == true
      self?.isOpaque = reduced
      self?.backgroundColor = reduced
        ? NSColor(srgbRed: 9.0 / 255.0, green: 9.0 / 255.0, blue: 11.0 / 255.0, alpha: 1)
        : NSColor.clear
      appearanceChannel.invokeMethod("accessibilityChanged", arguments: state)
    }
    glassController.onAccessibilityChange?(glassController.accessibilityState)

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
