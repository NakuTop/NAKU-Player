import Cocoa
import Carbon

// Compile with the production controller; this process owns its test window.
// It does not launch or modify the installed NAKU/taskManagerRunner apps.
@main
struct DesktopWindowCheck {
  static func main() throws {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let previous = NSWorkspace.shared.frontmostApplication
    defer { previous?.activate(options: []) }
    let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 320, height: 120),
      styleMask: [.titled], backing: .buffered, defer: false)
    window.title = "NAKU 窗口功能检查"
    window.orderFront(nil)
    defer { window.orderOut(nil) }
    let controls = NakuDesktopWindowController(window: window)
    do {
      try controls.configure(hotkeyEnabled: true, shortcut: "command-b", translucent: false, opacity: 0.8)
      try controls.configure(hotkeyEnabled: false, shortcut: "command-b", translucent: false, opacity: 0.8)
      print("PASS: default Command+B registered and released")
    } catch { print("NOTE: Command+B is currently occupied by another app: \(error.localizedDescription)") }
    var events: [Bool] = []
    controls.onVisibilityChange = { events.append($0) }
    try controls.configure(hotkeyEnabled: true, shortcut: "control-option-b", translucent: false, opacity: 0.8)
    precondition(controls.state["registered"] as? Bool == true)
    precondition(window.alphaValue == 1)
    let competitor = NakuDesktopWindowController(window: window)
    do {
      try competitor.configure(hotkeyEnabled: true, shortcut: "control-option-b", translucent: false, opacity: 0.8)
      preconditionFailure("Duplicate global shortcut was accepted")
    } catch { print("PASS: conflicting global shortcut rejected") }
    try controls.configure(hotkeyEnabled: true, shortcut: "control-option-b", translucent: true, opacity: 0.45)
    if !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
      precondition(abs(window.alphaValue - 0.45) < 0.001)
      controls.previewOpacity(-8)
      precondition(abs(window.alphaValue - 0.3) < 0.001)
    }
    try controls.configure(hotkeyEnabled: false, shortcut: "f8", translucent: false, opacity: 0.3)
    precondition(controls.state["registered"] as? Bool == false)
    precondition(window.alphaValue == 1)
    try competitor.configure(hotkeyEnabled: true, shortcut: "control-option-b", translucent: false, opacity: 0.8)
    print("PASS: disabled shortcut released; opacity restored and clamped")
    try competitor.configure(hotkeyEnabled: false, shortcut: "control-option-b", translucent: false, opacity: 0.8)
    try controls.configure(hotkeyEnabled: true, shortcut: "control-option-b", translucent: false, opacity: 0.8)
    let currentId = (UInt32(1)...100).first(where: controls.acceptsHotkey)!
    func send(_ kind: UInt32) {
      var event: EventRef?
      precondition(CreateEvent(nil, OSType(kEventClassKeyboard), kind, GetCurrentEventTime(), 0, &event) == noErr)
      guard let event = event else { preconditionFailure("Event creation failed") }
      defer { ReleaseEvent(event) }
      var identifier = EventHotKeyID(signature: 0x4E414B55, id: currentId)
      precondition(SetEventParameter(event, EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &identifier) == noErr)
      precondition(SendEventToEventTarget(event, GetApplicationEventTarget()) == noErr)
    }
    send(UInt32(kEventHotKeyPressed))
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    precondition(controls.hidden)
    send(UInt32(kEventHotKeyPressed))
    precondition(controls.hidden, "A held key must not toggle repeatedly")
    send(UInt32(kEventHotKeyReleased))
    send(UInt32(kEventHotKeyPressed))
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))
    send(UInt32(kEventHotKeyReleased))
    precondition(!controls.hidden && window.isVisible)
    precondition(events == [true, false])
    print("PASS: native hotkey events hide/show the same window; held key ignored until release")
  }
}
