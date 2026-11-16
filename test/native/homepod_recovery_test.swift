import Foundation

@main
struct RecoveryTests {
  static func drain() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15)) }
  static func speaker(_ address: String) -> NakuHomePodAudio.Speaker {
    .init(id: "test-homepod", name: "Fixture", address: address, model: "HomePod", port: 7000)
  }
  static func main() {
    let app = NakuHomePodAudio()
    app.selected = speaker("127.0.0.2")
    app.recovery.request()
    app.fail("Audio UDP send: No route to host", reconnect: true)
    drain()
    precondition(app.status == "reconnecting" && app.reconnectTimer != nil)
    app.reconnectTimer?.fire()
    precondition(app.discoveryTimer != nil)
    app.speakers["test-homepod"] = speaker("127.0.0.1")
    app.finishDiscovery()
    drain()
    precondition(app.status == "streaming" && app.sender?.address == "127.0.0.1", "Must resolve new address and restart capture")
    app.fail("transport closed", reconnect: true)
    drain()
    app.reconnectTimer?.fire()
    // An in-flight discovery must not resurrect a manually disabled session.
    app.disable()
    app.speakers["test-homepod"] = speaker("127.0.0.1")
    app.finishDiscovery()
    drain()
    precondition(!app.enabled && app.reconnectTimer == nil && !app.recovery.wanted)
    app.recovery.request()
    app.fail("transport closed", reconnect: true)
    drain()
    NakuVirtualAudioDriver.output = 99
    app.reconnectTimer?.fire()
    precondition(!app.recovery.wanted && app.reconnectTimer == nil, "Do not override a user's new output")
    app.recovery.request()
    app.recovery.sleeping = true
    app.interrupt("sleep", message: "sleep")
    drain()
    precondition(app.reconnectTimer == nil)
    app.recovery.sleeping = false
    app.scheduleReconnect()
    precondition(app.reconnectTimer != nil)
    app.shutdown()
    drain()
    precondition(app.reconnectTimer == nil && !app.recovery.wanted)
    print("PASS controller: UDP failure -> rediscovery -> new address -> streaming; disable during discovery; output change; sleep/wake; shutdown")
  }
}
