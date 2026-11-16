import Foundation

/// A cancellation token whose lock never covers IPC or audio device work.
/// Capture start/stop operations run on the owner's serial session queue.
final class NakuHomePodSessionGuard {
  private let lock = NSLock()
  private var generation: UInt64?

  func begin(_ generation: UInt64) {
    lock.lock(); defer { lock.unlock() }
    self.generation = generation
  }

  func isCurrent(_ generation: UInt64) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return self.generation == generation
  }

  func invalidate() {
    lock.lock(); defer { lock.unlock() }
    generation = nil
  }
}

/// Path updates are advisory. Brief loss can recover without replacing the
/// AirPlay connection, which separately reports control-channel failures.
enum NakuHomePodNetworkAction: Equatable {
  case cancelLoss, confirmLoss

  init(available: Bool) {
    self = available ? .cancelLoss : .confirmLoss
  }
}

/// Main-thread retry intent, independent of the current socket/capture lifetime.
struct NakuHomePodRecovery {
  private(set) var wanted = false
  var sleeping = false
  private var attempts = 0

  mutating func request() { wanted = true }
  mutating func connected() { attempts = 0 }
  mutating func cancel() { wanted = false; attempts = 0 }
  mutating func nextDelay() -> TimeInterval? {
    guard wanted, !sleeping else { return nil }
    let delay = min(15, 2 * pow(2, Double(min(attempts, 3))))
    attempts = min(attempts + 1, 3)
    return delay
  }
}
