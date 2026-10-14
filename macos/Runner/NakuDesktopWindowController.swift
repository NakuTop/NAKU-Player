import Cocoa
import Carbon

private func nakuVisibilityHotKeyHandler(
  _ nextHandler: EventHandlerCallRef?, _ event: EventRef?, _ context: UnsafeMutableRawPointer?
) -> OSStatus {
  guard let event = event, let context = context else { return OSStatus(eventNotHandledErr) }
  var identifier = EventHotKeyID()
  let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
    EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
  guard status == noErr, identifier.signature == 0x4E414B55 else {
    return OSStatus(eventNotHandledErr)
  }
  let controller = Unmanaged<NakuDesktopWindowController>.fromOpaque(context).takeUnretainedValue()
  return controller.handleHotkey(identifier.id, pressed: GetEventKind(event) == UInt32(kEventHotKeyPressed))
    ? noErr : OSStatus(eventNotHandledErr)
}

/// Independent AppKit implementation of visibility and whole-window opacity.
/// Carbon hotkeys work while hidden without a keyboard/event-monitor permission.
final class NakuDesktopWindowController: NSObject {
  struct Shortcut {
    let key: UInt32
    let modifiers: UInt32
  }
  static let shortcuts: [String: Shortcut] = [
    "control-option-b": Shortcut(key: UInt32(kVK_ANSI_B), modifiers: UInt32(controlKey | optionKey)),
    "command-shift-h": Shortcut(key: UInt32(kVK_ANSI_H), modifiers: UInt32(cmdKey | shiftKey)),
    "command-b": Shortcut(key: UInt32(kVK_ANSI_B), modifiers: UInt32(cmdKey)),
    "f8": Shortcut(key: UInt32(kVK_F8), modifiers: 0),
    "f9": Shortcut(key: UInt32(kVK_F9), modifiers: 0),
  ]

  private weak var window: NSWindow?
  private var eventHandler: EventHandlerRef?
  private var hotKey: EventHotKeyRef?
  private var observers: [NSObjectProtocol] = []
  private var shortcutName: String?
  private static var nextHotkeyId: UInt32 = 1
  private var activeHotkeyId: UInt32?
  private var hotkeyDown = false
  private var reportedHidden = false
  private var translucent = false
  private var opacity: Double = 0.8
  var onVisibilityChange: ((Bool) -> Void)?
  var onStateChange: (([String: Any]) -> Void)?

  // AppKit may temporarily unorder the window at startup, during fullscreen or
  // when changing Spaces. That is not the user's Hide action.
  var hidden: Bool { NSApp.isHidden }
  var state: [String: Any] {
    ["hidden": hidden, "registered": hotKey != nil,
     "reduceTransparency": NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency,
     "opacity": window?.alphaValue ?? 1.0]
  }

  init(window: NSWindow) {
    self.window = window
    super.init()
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: NSApplication.didHideNotification,
      object: NSApp, queue: .main) { [weak self] _ in self?.reportVisibility(true, force: true) })
    observers.append(center.addObserver(forName: NSApplication.didUnhideNotification,
      object: NSApp, queue: .main) { [weak self] _ in self?.reportVisibility(false, force: true) })
    for (name, object) in [
      (NSApplication.didBecomeActiveNotification, NSApp as AnyObject),
      (NSWindow.didBecomeKeyNotification, window as AnyObject),
    ] {
      observers.append(center.addObserver(forName: name, object: object, queue: .main) { [weak self] _ in
        // Sample at delivery time so an old activation cannot undo a new hide.
        DispatchQueue.main.async { [weak self] in
          guard let self = self else { return }
          self.reportVisibility(self.hidden, force: true)
        }
      })
    }
    observers.append(NSWorkspace.shared.notificationCenter.addObserver(
      forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
      object: nil, queue: .main) { [weak self] _ in
        self?.applyOpacity()
        if let self = self { self.onStateChange?(self.state) }
      })
  }

  deinit {
    if let key = hotKey { UnregisterEventHotKey(key) }
    if let handler = eventHandler { RemoveEventHandler(handler) }
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
      NSWorkspace.shared.notificationCenter.removeObserver(observer)
    }
  }

  func configure(hotkeyEnabled: Bool, shortcut: String, translucent: Bool, opacity: Double) throws {
    guard let selected = Self.shortcuts[shortcut], opacity.isFinite else {
      throw NSError(domain: "NAKUWindow", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "窗口设置无效。"])
    }
    if hotkeyEnabled && (hotKey == nil || shortcutName != shortcut) {
      if eventHandler == nil {
        var types = [
          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        let status = InstallEventHandler(GetApplicationEventTarget(), nakuVisibilityHotKeyHandler,
          2, &types, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        guard status == noErr else {
          throw NSError(domain: "NAKUWindow", code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "无法注册全局快捷键，请使用菜单或托盘。"])
        }
      }
      // Register first; a rejected replacement leaves the working old key intact.
      var replacement: EventHotKeyRef?
      let identifier = EventHotKeyID(signature: 0x4E414B55, id: Self.nextHotkeyId)
      let status = RegisterEventHotKey(selected.key, selected.modifiers, identifier,
        GetApplicationEventTarget(), 0, &replacement)
      guard status == noErr, let replacement = replacement else {
        throw NSError(domain: "NAKUWindow", code: Int(status),
          userInfo: [NSLocalizedDescriptionKey: "快捷键已被其他应用占用，请选择另一组快捷键。"])
      }
      Self.nextHotkeyId &+= 1
      if let old = hotKey { UnregisterEventHotKey(old) }
      hotKey = replacement
      activeHotkeyId = identifier.id
      hotkeyDown = false
      shortcutName = shortcut
    } else if !hotkeyEnabled {
      if let old = hotKey { UnregisterEventHotKey(old) }
      hotKey = nil
      activeHotkeyId = nil
      hotkeyDown = false
      shortcutName = nil
    }
    self.translucent = translucent
    self.opacity = max(0.3, min(1, opacity))
    applyOpacity()
  }

  func previewOpacity(_ value: Double) {
    guard value.isFinite else { return }
    opacity = max(0.3, min(1, value))
    applyOpacity()
  }

  private func applyOpacity() {
    window?.alphaValue = translucent && !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
      ? CGFloat(opacity) : 1.0
  }

  private func reportVisibility(_ value: Bool, force: Bool = false) {
    guard force || value != reportedHidden else { return }
    reportedHidden = value
    onVisibilityChange?(value)
  }

  func hide() {
    reportVisibility(true, force: true)
    NSApp.hide(nil)
  }

  func show() {
    NSApp.unhide(nil)
    if window?.isMiniaturized == true { window?.deminiaturize(nil) }
    window?.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    // Explicit Show must repair Flutter's cached state even if AppKit was
    // already unhidden and therefore did not send didUnhideNotification.
    reportVisibility(false, force: true)
  }

  @objc func toggleWindow(_ sender: Any?) {
    if hidden || window?.isMiniaturized == true { show() } else { hide() }
  }

  func handleHotkey(_ id: UInt32, pressed: Bool) -> Bool {
    guard acceptsHotkey(id) else { return false }
    if pressed {
      if !hotkeyDown {
        hotkeyDown = true
        toggleWindow(nil)
      }
    } else {
      hotkeyDown = false
    }
    return true
  }

  func acceptsHotkey(_ id: UInt32) -> Bool { hotKey != nil && activeHotkeyId == id }
}
