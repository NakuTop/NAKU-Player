import Foundation
import CoreAudio

enum NakuAirPlayError: Error { case invalid(String) }
enum NakuVirtualAudioError: Error { case unavailable(String), driverRequired, authorizationRequired }
enum NakuAudioLog { static func write(_ format: String, _ args: CVarArg...) {} }
enum NakuVirtualAudioDriver {
  static var installed = true, authorized = true, ready = true, registered = true
  static var output: AudioDeviceID = 42
  static let uid = "fixture"
  static var state: [String: Any] { [:] }
  static func recoverInterruptedRoute() {}
  static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID { output }
  static func deviceUID(_ id: AudioDeviceID) -> String { uid }
}
final class NakuVirtualAudioCapture {
  var onError: ((Error) -> Void)?
  let isRefreshingRoute = false
  init(_ receive: @escaping (Data) -> Void) {}
  func start(shouldContinue: () -> Bool) throws {}
  func stop() {}
}
final class NakuAirPlaySender {
  let address: String
  var isConnected = true
  var lastError: String?
  var onDiagnostic: ((String) -> Void)?
  let initialReceiverVolume: Double? = 0.4
  let packetsSent: UInt64 = 0, underruns: UInt64 = 0, droppedFrames: UInt64 = 0
  let lateSends: UInt64 = 0, clockResets: UInt64 = 0, retransmitRequests: UInt64 = 0
  let bufferedFrames = 0, driftPPM = 0.0
  init(address: String, port: UInt16, latencyMs: Int, systemCapture: Bool) { self.address = address }
  func connect() throws {}
  func setReceiverVolume(_ volume: Double) throws {}
  func writePCM(_ data: Data) {}
  func close() {}
}
