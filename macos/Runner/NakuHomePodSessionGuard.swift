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

/// A first satisfied path is only a baseline. Later loss or egress-interface
/// replacement for the HomePod destination needs an explicit new session.
/// This is not the global/default Internet path.
struct NakuHomePodNetworkRoute: Equatable {
  let available: Bool
  let interfaces: [String]

  func interrupts(_ previous: Self?) -> Bool {
    !available || (previous != nil && previous!.interfaces != interfaces)
  }
}
