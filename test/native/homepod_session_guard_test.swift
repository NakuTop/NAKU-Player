import Foundation

@main
struct SessionGuardTests {
  static func main() {
    let gate = NakuHomePodSessionGuard()
    gate.begin(1)
    precondition(gate.isCurrent(1))
    gate.invalidate()
    precondition(!gate.isCurrent(1))
    gate.begin(2)
    precondition(!gate.isCurrent(1))
    precondition(gate.isCurrent(2))

    // Model a slow XPC stage on the same serial queue used for start/stop.
    // Cancelling on the UI thread must not wait for that stage to finish.
    let session = DispatchQueue(label: "test.capture-session")
    let entered = DispatchSemaphore(value: 0)
    let finishIPC = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)
    var activeRoute = 0
    gate.begin(3)
    session.async {
      guard gate.isCurrent(3) else { preconditionFailure("start rejected early") }
      entered.signal()
      precondition(finishIPC.wait(timeout: .now() + 2) == .success)
      // The real tap repeats this check after attach/arm and before routing.
      if gate.isCurrent(3) { activeRoute = 3 }
    }
    precondition(entered.wait(timeout: .now() + 2) == .success)
    let before = ProcessInfo.processInfo.systemUptime
    gate.invalidate()
    precondition(ProcessInfo.processInfo.systemUptime - before < 0.1,
                 "Cancellation must not wait for capture IPC")
    session.async { activeRoute = 0 }
    gate.begin(4)
    session.async {
      if gate.isCurrent(4) { activeRoute = 4 }
      done.signal()
    }
    finishIPC.signal()
    precondition(done.wait(timeout: .now() + 2) == .success)
    precondition(activeRoute == 4, "An old queued stop must finish before a new start")

    let wifi = NakuHomePodNetworkRoute(available: true, interfaces: ["en0"])
    let ethernet = NakuHomePodNetworkRoute(available: true, interfaces: ["en5"])
    let down = NakuHomePodNetworkRoute(available: false, interfaces: [])
    precondition(!wifi.interrupts(nil))
    precondition(!wifi.interrupts(wifi))
    precondition(ethernet.interrupts(wifi))
    precondition(down.interrupts(wifi))
    precondition(down.interrupts(nil))
    print("PASS immediate cancellation during IPC, stale startup rejection, ordered cleanup/new session, destination-path policy")
  }
}
