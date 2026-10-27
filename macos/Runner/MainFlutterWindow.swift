import Cocoa
import FlutterMacOS
import window_manager
import CFNetwork
import SystemConfiguration
import CryptoKit
import Sparkle
import Security
import LocalAuthentication

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

// Observe Sparkle's verified feed and keep automatic update prompts visible.
// Archive/feed signature validation and installation remain owned by Sparkle.
private final class NakuUpdaterObserver: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
  weak var controller: SPUStandardUpdaterController?
  private var installationPromptPending = false
  private var playbackSessions = Set<String>()
  private var deferredInstallation: (() -> Void)?
  private var installationGeneration = 0
  private var installationDeferred = false
  var isWatchingVideo: Bool { !playbackSessions.isEmpty }

  func setPlaybackSession(_ id: String, active: Bool) {
    if active { playbackSessions.insert(id) } else { playbackSessions.remove(id) }
    guard !isWatchingVideo, let resume = deferredInstallation else { return }
    deferredInstallation = nil
    let generation = installationGeneration
    // The user already confirmed installation. Resume only after every
    // playback route (including paused/buffering/PiP video) has been closed.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.installationGeneration == generation else { return }
      if self.isWatchingVideo { self.deferredInstallation = resume }
      else {
        // Keep the deferred marker until Sparkle finishes/aborts: its resume
        // handler may itself enqueue work before the final relaunch gate.
        resume()
      }
    }
  }

  func cancelDeferredInstallation() {
    installationGeneration += 1
    installationDeferred = false
    deferredInstallation = nil
  }

  func updaterShouldRelaunchApplication(_ updater: SPUUpdater) -> Bool {
    // Sparkle 2.10 checks this before sending any Stage 2/termination command.
    // Its postponement hook runs only once per driver: a second Install click
    // while watching must abort that attempt rather than bypass the hook.
    if isWatchingVideo && installationDeferred {
      cancelDeferredInstallation()
      status = "更新已保留；请退出播放页后再次确认安装"
      return false
    }
    return true
  }

  func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice,
      forUpdate item: SUAppcastItem, state: SPUUserUpdateState) {
    if choice != .install { cancelDeferredInstallation() }
  }
  func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
      untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
    guard isWatchingVideo else { return false }
    status = "更新已就绪；退出播放页后安装并重启"
    installationDeferred = true
    deferredInstallation = installHandler
    return true
  }
  var latestVersion = "", latestBuild = "", lastError = "", status = "等待检查"

  func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
    lastError = ""
    if let latest = appcast.items.max(by: {
      $0.versionString.compare($1.versionString, options: .numeric) == .orderedAscending
    }) {
      latestVersion = latest.displayVersionString
      latestBuild = latest.versionString
    }
    status = "检查完成"
  }
  func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
    status = "发现新版本 \(item.displayVersionString)"
    // Do not foreground a background check here: Sparkle must finish its
    // automatic download before we ask it to show the installation prompt.
  }
  func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem,
      with request: NSMutableURLRequest) {
    status = "正在自动下载 \(item.displayVersionString)"
  }
  func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
    status = "下载完成，正在验证更新"
  }
  func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
      immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
    status = "更新已准备好，请确认安装并重启"
    // The automatic driver is still active here. Let it finish before
    // asking Sparkle to resume the staged installation with its normal UI.
    installationPromptPending = true
    return false
  }
  func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
      error: Error?) {
    if error != nil { cancelDeferredInstallation() }
    guard installationPromptPending else { return }
    installationPromptPending = false
    guard error == nil, updater.automaticallyChecksForUpdates,
      updater.automaticallyDownloadsUpdates else { return }
    controller?.checkForUpdates(nil)
  }

  func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
    cancelDeferredInstallation()
    let failure = error as NSError
    if failure.domain == SUSparkleErrorDomain && failure.code == 1001 {
      status = "当前没有可安装的新版本"
      return
    }
    lastError = "更新失败（\(failure.code)）：\(failure.localizedDescription)"
    status = "检查或安装失败"
  }
  func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
      forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
    guard handleShowingUpdate, !state.userInitiated else { return }
    // Sparkle explicitly permits promoting an existing scheduled update via
    // checkForUpdates. Do it on the next loop after the alert is constructed.
    DispatchQueue.main.async { [weak self] in self?.controller?.checkForUpdates(nil) }
  }
}

// An original, quiet synthesized chord, not an Apple recording or system sound.
// This owner lives with its window and never requests capture/audio permissions.
private final class NakuCinemaStartupSound {
  private weak var window: NSWindow?
  private var sound: NSSound?
  private var activeGeneration: Int64?
  private var highestGeneration: Int64?
  private var observers = [NSObjectProtocol]()

  init(window: NSWindow) {
    self.window = window
    let center = NotificationCenter.default
    for name in [NSApplication.didResignActiveNotification,
                 NSApplication.didHideNotification,
                 NSApplication.willTerminateNotification] {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
        [weak self] _ in self?.stop()
      })
    }
    for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification] {
      observers.append(center.addObserver(forName: name, object: window, queue: .main) {
        [weak self] _ in self?.stop()
      })
    }
  }

  deinit {
    stop()
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
  }

  func stop(generation: Int64? = nil) {
    if let generation, activeGeneration != generation { return }
    sound?.stop()
    sound = nil
    activeGeneration = nil
  }

  func play(generation: Int64, volume: Double) throws -> Bool {
    // Tokens are globally increasing across Dart player instances. Neither a
    // duplicate ready notification nor an old route may replay a completed cue.
    if let highestGeneration, generation <= highestGeneration { return false }
    stop()
    guard NSApp.isActive, !NSApp.isHidden,
          let window, window.isVisible, !window.isMiniaturized else { return false }
    highestGeneration = generation
    let quietVolume = min(0.25, max(0, volume))
    guard quietVolume > 0 else { return false }
    let url = try Self.cachedWaveURL()
    guard let prepared = NSSound(contentsOf: url, byReference: false) else {
      throw NSError(domain: "naku.cinema-startup-sound", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "无法准备影院提示音。"])
    }
    prepared.loops = false
    prepared.volume = Float(quietVolume)
    guard prepared.play() else {
      throw NSError(domain: "naku.cinema-startup-sound", code: 2,
        userInfo: [NSLocalizedDescriptionKey: "当前音频输出暂不可用。"])
    }
    sound = prepared
    activeGeneration = generation
    return true
  }

  private static func cachedWaveURL() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      Bundle.main.bundleIdentifier ?? "naku-player", isDirectory: true)
      .appendingPathComponent("cinema-audio", isDirectory: true)
    try FileManager.default.createDirectory(at: directory,
      withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let url = directory.appendingPathComponent("original-startup-chord-v1.wav")
    if !FileManager.default.fileExists(atPath: url.path) {
      try waveData().write(to: url, options: .atomic)
    }
    return url
  }

  private static func waveData() -> Data {
    let sampleRate = 22_050
    let duration = 0.92
    let samples = Int(Double(sampleRate) * duration)
    let pcmBytes = samples * 2
    var data = Data(capacity: 44 + pcmBytes)
    func word(_ value: UInt16) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    func dword(_ value: UInt32) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    data.append(contentsOf: "RIFF".utf8)
    dword(UInt32(36 + pcmBytes))
    data.append(contentsOf: "WAVEfmt ".utf8)
    dword(16)
    word(1) // Linear PCM.
    word(1) // Mono; no synthetic spatial movement over the video soundtrack.
    dword(UInt32(sampleRate))
    dword(UInt32(sampleRate * 2))
    word(2)
    word(16)
    data.append(contentsOf: "data".utf8)
    dword(UInt32(pcmBytes))

    let frequencies = [164.8138, 329.6276, 415.3047, 493.8833, 739.9888]
    let weights = [0.20, 0.28, 0.18, 0.22, 0.12]
    for index in 0..<samples {
      let time = Double(index) / Double(sampleRate)
      let attack = pow(sin(min(1, time / 0.065) * .pi / 2), 2)
      let release = pow(max(0, 1 - time / duration), 2.4)
      var signal = 0.0
      for voice in frequencies.indices {
        let localTime = max(0, time - Double(voice) * 0.006)
        let phase = 2 * Double.pi * frequencies[voice] * localTime
        signal += weights[voice] * (sin(phase) + 0.08 * sin(phase * 2))
      }
      let value = Int16((min(1, max(-1, signal * attack * release * 0.58))
        * Double(Int16.max)).rounded())
      word(UInt16(bitPattern: value))
    }
    return data
  }
}

class MainFlutterWindow: NSWindow {
  // Keep the engine owner explicit; the window's root controller is the glass
  // container, while all plugin registrars still belong to this Flutter child.
  private(set) var flutterViewController: FlutterViewController?
  private var updaterController: SPUStandardUpdaterController?
  private let updaterObserver = NakuUpdaterObserver()
  func setNativePlaybackSession(_ id: String, active: Bool) {
    updaterObserver.setPlaybackSession("native-" + id, active: active)
  }
  private var downloadActivity: NSObjectProtocol?
  private let nasMovies = NakuNASMovies()
  private var desktopControls: NakuDesktopWindowController?
  private var cinemaStartupSound: NakuCinemaStartupSound?

  deinit {
    cinemaStartupSound?.stop()
    if let activity = downloadActivity { ProcessInfo.processInfo.endActivity(activity) }
  }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    // Match native titlebar/sheets to the cinema surface, not the light desktop.
    self.appearance = NSAppearance(named: .darkAqua)
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
    NakuSubtitleTools.register(with: flutterViewController.engine.binaryMessenger)
    let nasChannel = FlutterMethodChannel(name: "naku/nas-movies", binaryMessenger: flutterViewController.engine.binaryMessenger)
    nasChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { result(nil); return }
      self.nasMovies.handle(call, result: result)
    }


    let desktopControls = NakuDesktopWindowController(window: self)
    self.desktopControls = desktopControls
    cinemaStartupSound = NakuCinemaStartupSound(window: self)
    let desktopChannel = FlutterMethodChannel(name: "naku/desktop-controls",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    desktopControls.onVisibilityChange = { [weak self] hidden in
      if hidden { self?.cinemaStartupSound?.stop() }
      desktopChannel.invokeMethod("visibilityChanged", arguments: ["hidden": hidden])
    }
    desktopControls.onStateChange = { state in
      desktopChannel.invokeMethod("stateChanged", arguments: state)
    }
    desktopChannel.setMethodCallHandler { [weak self, weak desktopControls] call, result in
      guard let controls = desktopControls else { result(nil); return }
      switch call.method {
      case "state": result(controls.state)
      case "configure":
        guard let args = call.arguments as? [String: Any],
              let enabled = args["hotkeyEnabled"] as? Bool,
              let shortcut = args["shortcut"] as? String,
              let translucent = args["translucent"] as? Bool,
              let opacity = args["opacity"] as? Double else {
          result(FlutterError(code: "invalid", message: "窗口设置无效。", details: nil)); return
        }
        do {
          try controls.configure(hotkeyEnabled: enabled, shortcut: shortcut,
            translucent: translucent, opacity: opacity)
          result(controls.state)
        } catch {
          result(FlutterError(code: "window_configuration", message: error.localizedDescription, details: nil))
        }
      case "previewOpacity":
        guard let opacity = call.arguments as? Double else {
          result(FlutterError(code: "invalid", message: "透明度无效。", details: nil)); return
        }
        controls.previewOpacity(opacity)
        result(nil)
      case "hide": controls.hide(); result(nil)
      case "show": controls.show(); result(nil)
      case "playCinemaStartupSound":
        guard let args = call.arguments as? [String: Any],
              let generation = args["generation"] as? Int64, generation >= 0,
              let volume = (args["volume"] as? NSNumber)?.doubleValue,
              volume.isFinite else {
          result(FlutterError(code: "invalid", message: "影院提示音参数无效。", details: nil)); return
        }
        do {
          result(try self?.cinemaStartupSound?.play(generation: generation, volume: volume) ?? false)
        } catch {
          result(FlutterError(code: "cinema_sound", message: error.localizedDescription, details: nil))
        }
      case "stopCinemaStartupSound":
        if let arguments = call.arguments, !(arguments is NSNull) {
          guard let args = arguments as? [String: Any],
                let generation = args["generation"] as? Int64 else {
            result(FlutterError(code: "invalid", message: "影院提示音代次无效。", details: nil)); return
          }
          self?.cinemaStartupSound?.stop(generation: generation)
        } else {
          self?.cinemaStartupSound?.stop()
        }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
    if let appMenu = NSApp.mainMenu?.items.first?.submenu {
      let toggle = NSMenuItem(title: "隐藏/显示窗口", action: #selector(NakuDesktopWindowController.toggleWindow(_:)), keyEquivalent: "")
      toggle.target = desktopControls
      appMenu.insertItem(toggle, at: min(3, appMenu.items.count))
    }

    for (channelName, service) in [
      ("naku/danmaku-credentials", "com.shenminghao.yingchuan.dandanplay"),
      ("naku/logvar-credentials", "com.shenminghao.yingchuan.logvar"),
    ] {
    let danmakuChannel = FlutterMethodChannel(
      name: channelName, binaryMessenger: flutterViewController.engine.binaryMessenger)
    let credentialQueue = DispatchQueue(label: "naku.credentials.\(service)", qos: .userInitiated)
    danmakuChannel.setMethodCallHandler { call, result in
      let respond: FlutterResult = { value in
        DispatchQueue.main.async { result(value) }
      }
      let handle = {
      var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: service,
        kSecAttrAccount as String: channelName == "naku/logvar-credentials" ? "nas-v1" : "client",
        kSecAttrSynchronizable as String: false,
      ]
      if channelName == "naku/logvar-credentials",
         let args = call.arguments as? [String: String], args["nonInteractive"] == "true" {
        let authentication = LAContext()
        authentication.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = authentication
      }
      func failure(_ status: OSStatus) {
        respond(FlutterError(code: "keychain", message: "无法访问本机钥匙串 (\(status))", details: nil))
      }
      switch call.method {
      case "read":
        var request = query
        if channelName == "naku/logvar-credentials" {
          let authentication = LAContext()
          authentication.interactionNotAllowed = true
          request[kSecUseAuthenticationContext as String] = authentication
        }
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &value)
        if status == errSecItemNotFound { respond(nil); return }
        guard status == errSecSuccess else { failure(status); return }
        guard let data = value as? Data,
              let credentials = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
          respond(FlutterError(code: "keychain_data", message: "弹幕凭据无法读取，请重新填写", details: nil))
          return
        }
        respond(credentials)
      case "save":
        guard let args = call.arguments as? [String: String],
              let id = args["id"], let secret = args["secret"],
              !id.isEmpty, !secret.isEmpty, id.count <= (channelName == "naku/logvar-credentials" ? 1024 : 256), secret.count <= 1024,
              !id.contains("\n"), !id.contains("\r"),
              !secret.contains("\n"), !secret.contains("\r"),
              let data = try? JSONSerialization.data(withJSONObject: ["id": id, "secret": secret]) else {
          respond(FlutterError(code: "invalid", message: "请填写有效的弹幕凭据", details: nil)); return
        }
        let updates = [kSecValueData as String: data] as CFDictionary
        var status = SecItemUpdate(query as CFDictionary, updates)
        if status == errSecItemNotFound {
          var item = query
          item[kSecValueData as String] = data
          item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
          status = SecItemAdd(item as CFDictionary, nil)
        }
        if status == errSecSuccess { respond(nil) } else { failure(status) }
      case "clear":
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { respond(nil) } else { failure(status) }
      default: respond(FlutterMethodNotImplemented)
      }
      }
      if channelName == "naku/logvar-credentials" {
        credentialQueue.async(execute: handle)
      } else { handle() }
    }

    }

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
      // Include a local-only network signature even when a hotel's HTTP proxy
      // configuration is identical to the home network. No Wi-Fi location
      // permission, network name, or address is sent to a remote service.
      if let store = SCDynamicStoreCreate(nil, "NAKU.RouteIdentity" as CFString, nil, nil) {
        let patterns = ["State:/Network/Global/IPv[46]", "State:/Network/Global/DNS",
                        "State:/Network/Service/.*/IPv[46]", "State:/Network/Service/.*/DHCP"]
        var state: [String: Any] = [:]
        func jsonValue(_ value: Any) -> Any {
          if let data = value as? Data { return data.base64EncodedString() }
          if let date = value as? Date { return date.timeIntervalSince1970 }
          if let values = value as? [String: Any] { return values.mapValues { jsonValue($0) } }
          if let values = value as? [Any] { return values.map { jsonValue($0) } }
          if value is String || value is NSNumber { return value }
          return String(describing: value)
        }
        for pattern in patterns {
          let keys = SCDynamicStoreCopyKeyList(store, pattern as CFString) as? [String] ?? []
          for key in keys {
            if let value = SCDynamicStoreCopyValue(store, key as CFString) {
              state[key] = jsonValue(value)
            }
          }
        }
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) {
          snapshot["NAKUNetworkSignature"] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
      }
      result(snapshot)
    }

    let downloadPowerChannel = FlutterMethodChannel(
      name: "naku/download-power", binaryMessenger: flutterViewController.engine.binaryMessenger)
    downloadPowerChannel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setActive", let active = call.arguments as? Bool else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let self = self else { result(nil); return }
      if active && self.downloadActivity == nil {
        // userInitiated prevents App Nap and idle system sleep, not display
        // sleep. macOS still honours lid close, explicit sleep and low battery.
        self.downloadActivity = ProcessInfo.processInfo.beginActivity(
          options: [.userInitiated], reason: "NAKU video downloads")
      } else if !active, let activity = self.downloadActivity {
        ProcessInfo.processInfo.endActivity(activity)
        self.downloadActivity = nil
      }
      result(nil)
    }

    // Keep one native controller alive for the window lifetime. Sparkle owns its
    // persisted preferences, signature validation, scheduler, and installer UI.
    let updater = SPUStandardUpdaterController(
      startingUpdater: true, updaterDelegate: updaterObserver, userDriverDelegate: updaterObserver)
    // Set the persisted value as well as Info.plist's fresh-install default:
    // existing installations must adopt the requested hourly schedule too.
    updater.updater.updateCheckInterval = 3600
    updaterController = updater
    updaterObserver.controller = updater
    // Sparkle recommends doing an additional launch check immediately after
    // start, before the next runloop; respect the persisted opt-out preference.
    if updater.updater.automaticallyChecksForUpdates {
      updater.updater.checkForUpdatesInBackground()
    }
    let updateChannel = FlutterMethodChannel(
      name: "naku/updater", binaryMessenger: flutterViewController.engine.binaryMessenger)
    updateChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "playbackSession":
        guard let args = call.arguments as? [String: Any],
          let id = args["id"] as? String, !id.isEmpty,
          let active = args["active"] as? Bool else {
          result(FlutterError(code: "arguments", message: "无效的播放状态", details: nil))
          return
        }
        self.updaterObserver.setPlaybackSession(id, active: active)
        result(nil)
      case "state":
        result([
          "checkIntervalSeconds": updater.updater.updateCheckInterval,
          "playbackProtected": self.updaterObserver.isWatchingVideo,
          "automaticChecks": updater.updater.automaticallyChecksForUpdates,
          "automaticDownloads": updater.updater.automaticallyDownloadsUpdates,
          "canCheck": updater.updater.canCheckForUpdates,
          "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
          "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
          "latestPublishedVersion": self.updaterObserver.latestVersion,
          "latestPublishedBuild": self.updaterObserver.latestBuild,
          "lastCheck": updater.updater.lastUpdateCheckDate?.timeIntervalSince1970 ?? 0,
          "status": self.updaterObserver.status,
          "lastError": self.updaterObserver.lastError
        ])
      case "check":
        self.updaterObserver.lastError = ""
        self.updaterObserver.status = "正在检查更新"
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
          if enabled && args["automaticChecks"] != false {
            updater.updater.automaticallyChecksForUpdates = true
          }
        }
        if args["automaticChecks"] == false {
          updater.updater.automaticallyDownloadsUpdates = false
        }
        // Let Sparkle reset its scheduler after preference changes. A
        // foreground check here would turn automatic downloads into a manual
        // update offer. Every subsequent app launch also checks immediately.
        updater.updater.resetUpdateCycleAfterShortDelay()
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
