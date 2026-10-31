import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Darwin
#if canImport(FlutterMacOS)
import FlutterMacOS
#endif

/// Opt-in system audio forwarding. Construction/state reads never start capture
/// or discovery. No enabled preference survives process exit.
final class NakuHomePodAudio: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
  static let shared = NakuHomePodAudio()
  var onEnabledChange: ((Bool) -> Void)?

  private struct Speaker {
    let id: String, name: String, address: String, model: String
    let port: Int
    var dictionary: [String: Any] {
      ["id": id, "name": name, "address": address, "port": port, "model": model]
    }
  }
  private let browser = NetServiceBrowser()
  private var services: [String: NetService] = [:]
  private var speakers: [String: Speaker] = [:]
  private var discoveryCompletions: [([String: Any]) -> Void] = []
  private var discoveryTimer: Timer?
  private let sessionQueue = DispatchQueue(label: "naku.homepod.session", qos: .userInitiated)
  private var sender: NakuAirPlaySender?
  private var capture: NakuVirtualAudioCapture?
  private var healthTimer: Timer?
  private var forwardingActivity: NSObjectProtocol?
  private var terminationObserver: NSObjectProtocol?
  private var generation: UInt64 = 0
  private var status = "off"
  private var enabled = false
  private var errorMessage: String?
  private var selected: Speaker?
  private var latencyMs = 120
  private var receiverVolume: Double = {
    let stored = UserDefaults.standard.object(forKey: "naku.homepod.receiverVolume") as? NSNumber
    let value = stored?.doubleValue ?? 40
    return value.isFinite ? min(100, max(0, value)) : 40
  }()
  private var capturedBytes: UInt64 = 0
  private var nonzeroSamples: UInt64 = 0
  private var peakSample = 0
  private var healthTicks = 0
  private let counterLock = NSLock()
  private var outputListener: AudioObjectPropertyListenerBlock?

  override init() {
    super.init()
    browser.delegate = self
    NakuVirtualAudioDriver.recoverInterruptedRoute()
    terminationObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.shutdown() }
  }

  var state: [String: Any] {
    counterLock.lock()
    let bytes = capturedBytes, nonzero = nonzeroSamples
    let peak = peakSample
    counterLock.unlock()
    var result: [String: Any] = [
      "supported": Self.supported, "enabled": enabled, "status": status,
      "devices": speakers.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        .map { $0.dictionary },
      "source": "system", "latencyMs": latencyMs,
      "routeActive": enabled && status == "streaming" && capture != nil,
      "receiverVolume": receiverVolume,
      "capturedFrames": NSNumber(value: bytes / 4),
      "nonzeroSamples": NSNumber(value: nonzero), "peakSample": peak,
      "packetsSent": NSNumber(value: sender?.packetsSent ?? 0)
    ]
    if let selected { result["deviceId"] = selected.id; result["deviceName"] = selected.name }
    if let errorMessage { result["error"] = errorMessage }
    return result.merging(NakuVirtualAudioDriver.state) { _, new in new }
  }

  private static var supported: Bool { true }

  func discover(completion: @escaping ([String: Any]) -> Void) {
    guard Self.supported else { completion(state); return }
    discoveryCompletions.append(completion)
    guard discoveryTimer == nil else { return }
    if !enabled { status = "discovering" }
    errorMessage = nil
    browser.stop()
    for service in services.values { service.stop() }
    services.removeAll(); speakers.removeAll()
    browser.searchForServices(ofType: "_airplay._tcp.", inDomain: "local.")
    discoveryTimer = Timer.scheduledTimer(withTimeInterval: 3.5, repeats: false) { [weak self] _ in
      self?.finishDiscovery()
    }
  }

  private func finishDiscovery() {
    discoveryTimer?.invalidate(); discoveryTimer = nil
    browser.stop()
    if status == "discovering" { status = "off" }
    let callbacks = discoveryCompletions; discoveryCompletions.removeAll()
    let value = state
    callbacks.forEach { $0(value) }
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
    let key = service.domain + service.type + service.name
    services[key] = service
    service.delegate = self
    service.resolve(withTimeout: 3)
  }

  func netServiceDidResolveAddress(_ service: NetService) {
    let txt = service.txtRecordData().map(NetService.dictionary(fromTXTRecord:)) ?? [:]
    func text(_ key: String) -> String? { txt[key].flatMap { String(data: $0, encoding: .utf8) } }
    let model = text("model") ?? ""
    // This sender is qualified against HomePod's realtime PCM profile. Other
    // AirPlay receiver formats must be qualified before exposing them here.
    guard model.hasPrefix("AudioAccessory") || model.lowercased().contains("homepod") else { return }
    guard let address = service.addresses?.compactMap(Self.ipv4).first,
          service.port > 0, service.port <= 65535 else { return }
    let id = text("deviceid") ?? service.domain + service.type + service.name
    speakers[id] = Speaker(id: id, name: service.name, address: address, model: model, port: service.port)
  }

  func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
    errorMessage = "无法查找 HomePod。请在系统设置中允许 NAKU 访问本地网络。"
    finishDiscovery()
  }

  private static func ipv4(_ data: Data) -> String? {
    guard data.count >= MemoryLayout<sockaddr_in>.size else { return nil }
    return data.withUnsafeBytes { raw -> String? in
      guard let base = raw.baseAddress else { return nil }
      let sa = base.assumingMemoryBound(to: sockaddr.self)
      guard sa.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
      var address = base.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
      var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
      guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
      return String(cString: buffer)
    }
  }

  func enable(id: String, requestedLatency: Int, completion: @escaping (Error?) -> Void) {
    guard NakuVirtualAudioDriver.installed else { completion(NakuVirtualAudioError.driverRequired); return }
    guard NakuVirtualAudioDriver.authorized else { completion(NakuVirtualAudioError.authorizationRequired); return }
    guard NakuVirtualAudioDriver.ready else { completion(NakuVirtualAudioError.unavailable("NAKU 虚拟声卡正在启动，请稍后重新开启。")); return }
    guard let speaker = speakers[id] else {
      completion(NakuAirPlayError.invalid("请先刷新并选择当前网络中的 HomePod。")); return
    }
    guard [120, 200, 300].contains(requestedLatency) else {
      completion(NakuAirPlayError.invalid("发送缓冲目标无效。")); return
    }
    stopSession()
    generation &+= 1
    let token = generation
    selected = speaker; latencyMs = requestedLatency
    enabled = true; status = "connecting"; errorMessage = nil
    // A user-enabled forwarding session must remain scheduled when its window
    // is covered or hidden. Allow ordinary system sleep; release on every stop.
    forwardingActivity = ProcessInfo.processInfo.beginActivity(
      options: .userInitiatedAllowingIdleSystemSleep,
      reason: "NAKU HomePod system audio")
    onEnabledChange?(true)
    counterLock.lock()
    capturedBytes = 0; nonzeroSamples = 0; peakSample = 0
    counterLock.unlock()
    let newSender = NakuAirPlaySender(address: speaker.address, port: UInt16(speaker.port), latencyMs: requestedLatency)
    let fallbackVolume = receiverVolume / 100
    newSender.onDiagnostic = { phase in NakuAudioLog.write("NAKUHomePod connection: %@", phase) }
    sessionQueue.async { [weak self] in
      do {
        try newSender.connect()
        let initialVolume = newSender.initialReceiverVolume ?? fallbackVolume
        if newSender.initialReceiverVolume == nil { try newSender.setReceiverVolume(initialVolume) }
        let wanted = DispatchQueue.main.sync {
          self.map { $0.generation == token && $0.enabled } ?? false
        }
        guard wanted else { throw NakuAirPlayError.invalid("连接已取消。") }
        let tap = NakuVirtualAudioCapture { [weak self, weak newSender] pcm in
          // Statistics are computed on the conversion queue, never in the HAL callback.
          var nonzero: UInt64 = 0
          var peak = 0
          pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for offset in stride(from: 0, to: raw.count - 1, by: 2) {
              let sample = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: offset, as: Int16.self)))
              if sample != 0 { nonzero &+= 1 }
              peak = max(peak, abs(sample))
            }
          }
          if let self {
            self.counterLock.lock()
            self.capturedBytes &+= UInt64(pcm.count)
            self.nonzeroSamples &+= nonzero
            self.peakSample = max(self.peakSample, peak)
            self.counterLock.unlock()
          }
          newSender?.writePCM(pcm)
        }
        tap.onError = { [weak self] error in
          DispatchQueue.main.async {
            guard let self, self.generation == token else { return }
            self.fail(error.localizedDescription)
          }
        }
        // Driver IPC and output-device changes stay off the UI thread.
        try tap.start()
        let accepted = DispatchQueue.main.sync { () -> Bool in
          guard let self, self.generation == token, self.enabled else { return false }
          self.sender = newSender
          self.capture = tap
          self.receiverVolume = initialVolume * 100
          self.status = "streaming"
          NakuAudioLog.write("NAKUHomePod system capture started; target=%d ms", self.latencyMs)
          self.monitorSession(token: token)
          completion(nil)
          return true
        }
        if !accepted {
          tap.stop()
          throw NakuAirPlayError.invalid("连接已取消。")
        }
      } catch {
        newSender.close()
        DispatchQueue.main.async {
          guard let self, self.generation == token else {
            completion(NakuAirPlayError.invalid("连接已取消。")); return
          }
          self.fail(error.localizedDescription)
          completion(error)
        }
      }
    }
  }

  private func monitorSession(token: UInt64) {
    healthTicks = 0
    healthTimer?.invalidate()
    healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      guard let self, self.generation == token else { return }
      self.healthTicks += 1
      if self.healthTicks <= 3 || self.healthTicks % 10 == 0 {
        self.counterLock.lock()
        let frames = self.capturedBytes / 4, nonzero = self.nonzeroSamples
        let peak = self.peakSample
        self.counterLock.unlock()
        NakuAudioLog.write("NAKUHomePod audio: frames=%llu nonzero=%llu peak=%d packets=%llu",
              frames, nonzero, peak, self.sender?.packetsSent ?? 0)
      }
      if let sender = self.sender, !sender.isConnected || sender.lastError != nil {
        self.fail(sender.lastError ?? "HomePod 连接已断开，已恢复本机声音。")
      }
    }
    var property = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self, self.generation == token, self.enabled,
            NakuVirtualAudioDriver.deviceUID(NakuVirtualAudioDriver.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)) != NakuVirtualAudioDriver.uid else { return }
      self.fail("系统音频输出已更改，已停止 HomePod 转发。需要时可重新开启。")
    }
    if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener) == noErr {
      outputListener = listener
    }
  }

  func disable() {
    generation &+= 1
    stopSession()
    status = "off"; errorMessage = nil
  }

  func setReceiverVolume(_ percent: Double, completion: @escaping (Error?) -> Void) {
    guard percent.isFinite, (0...100).contains(percent) else {
      completion(NakuVirtualAudioError.unavailable("HomePod 音量必须在 0 到 100 之间。")); return
    }
    guard enabled, status == "streaming", let current = sender else {
      completion(NakuVirtualAudioError.unavailable("请先连接 HomePod，再调整音量。")); return
    }
    let token = generation
    sessionQueue.async { [weak self] in
      do {
        let wanted = DispatchQueue.main.sync { self.map { $0.enabled && $0.generation == token } ?? false }
        guard wanted else { throw NakuVirtualAudioError.unavailable("音量调整已取消。") }
        try current.setReceiverVolume(percent / 100)
        DispatchQueue.main.async {
          guard let self, self.generation == token else {
            completion(NakuVirtualAudioError.unavailable("音量调整已取消。")); return
          }
          self.receiverVolume = percent
          UserDefaults.standard.set(percent, forKey: "naku.homepod.receiverVolume")
          NakuAudioLog.write("NAKUHomePod receiver volume: %.0f%%", percent)
          completion(nil)
        }
      } catch { DispatchQueue.main.async { completion(error) } }
    }
  }

  func testDriver(completion: @escaping ([String: Any]?, Error?) -> Void) {
    guard !enabled, capture == nil else {
      completion(nil, NakuVirtualAudioError.unavailable("请先关闭 HomePod 输出，再检查声卡。")); return
    }
    guard NakuVirtualAudioDriver.installed else { completion(nil, NakuVirtualAudioError.driverRequired); return }
    guard NakuVirtualAudioDriver.authorized else { completion(nil, NakuVirtualAudioError.authorizationRequired); return }
    guard NakuVirtualAudioDriver.ready else { completion(nil, NakuVirtualAudioError.unavailable("NAKU 虚拟声卡尚未就绪，请稍后检查。")); return }
    generation &+= 1
    let token = generation
    let original = NakuVirtualAudioDriver.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    let originalSystem = NakuVirtualAudioDriver.defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
    let lock = NSLock()
    var frames: UInt64 = 0, nonzero: UInt64 = 0
    var streamError: Error?
    let tap = NakuVirtualAudioCapture { data in
      var count: UInt64 = 0
      data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for offset in stride(from: 0, to: raw.count - 1, by: 2) {
          if raw.loadUnaligned(fromByteOffset: offset, as: Int16.self) != 0 { count += 1 }
        }
      }
      lock.lock(); frames += UInt64(data.count / 4); nonzero += count; lock.unlock()
    }
    tap.onError = { error in lock.lock(); streamError = error; lock.unlock() }
    capture = tap; onEnabledChange?(true)
    sessionQueue.async { [weak self] in
      var result: [String: Any]?, failure: Error?
      do {
        try tap.start()
        let wanted = DispatchQueue.main.sync { self.map { $0.generation == token } ?? false }
        guard wanted else { throw NakuVirtualAudioError.unavailable("声卡检查已取消。") }
        let player = try AVAudioPlayer(data: Self.testSignal())
        guard player.play() else { throw NakuVirtualAudioError.unavailable("无法播放声卡测试信号。") }
        Thread.sleep(forTimeInterval: 0.85)
        player.stop(); tap.stop()
        lock.lock(); let values = (frames, nonzero, streamError); lock.unlock()
        if let error = values.2 { throw error }
        guard values.0 > 0, values.1 > 0 else { throw NakuVirtualAudioError.unavailable("声卡未收到有效声音，请重新安装驱动后再检查。") }
        let restored = NakuVirtualAudioDriver.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) == original &&
          NakuVirtualAudioDriver.defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice) == originalSystem
        guard restored else { throw NakuVirtualAudioError.unavailable("声卡已收到声音，请确认系统声音输出已恢复为原设备。") }
        NakuAudioLog.write("NAKUHomePod driver test PASS: frames=%llu nonzero=%llu restored=1", values.0, values.1)
        result = ["success": true, "frames": NSNumber(value: values.0), "nonzeroSamples": NSNumber(value: values.1), "restored": true]
      } catch { tap.stop(); failure = error; NakuAudioLog.write("NAKUHomePod driver test failed: %@", error.localizedDescription) }
      DispatchQueue.main.async {
        guard let self else { return }
        if self.generation == token { self.capture = nil; self.onEnabledChange?(false) }
        completion(result, failure)
      }
    }
  }

  private static func testSignal() -> Data {
    let frames = 24000, byteCount = frames * 4
    var data = Data("RIFF".utf8)
    func append<T: FixedWidthInteger>(_ value: T) {
      var little = value.littleEndian
      withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
    }
    append(UInt32(36 + byteCount)); data.append(Data("WAVEfmt ".utf8))
    append(UInt32(16)); append(UInt16(1)); append(UInt16(2)); append(UInt32(48000))
    append(UInt32(192000)); append(UInt16(4)); append(UInt16(16))
    data.append(Data("data".utf8)); append(UInt32(byteCount))
    for frame in 0..<frames {
      let envelope = min(1, Double(frame) / 480, Double(frames - frame) / 480)
      let value = Int16(700 * envelope * sin(Double(frame) * 2 * .pi * 523.25 / 48000))
      append(value); append(value)
    }
    return data
  }

  private func fail(_ message: String) {
    NakuAudioLog.write("NAKUHomePod stopped: %@", message)
    generation &+= 1
    stopSession()
    status = "error"; errorMessage = message
  }

  private func stopSession() {
    healthTimer?.invalidate(); healthTimer = nil
    if let activity = forwardingActivity {
      ProcessInfo.processInfo.endActivity(activity)
      forwardingActivity = nil
    }
    if let listener = outputListener {
      var property = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
      AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &property, .main, listener)
      outputListener = nil
    }
    capture?.stop(); capture = nil
    NakuAudioLog.write("NAKUHomePod capture released")
    let previous = sender; sender = nil
    enabled = false; onEnabledChange?(false)
    if let previous { sessionQueue.async { previous.close() } }
  }

  func shutdown() {
    disable()
    browser.stop(); services.values.forEach { $0.stop() }
    discoveryTimer?.invalidate(); discoveryTimer = nil
  }

#if canImport(FlutterMacOS)
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "naku/homepod-audio", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      let controls = Self.shared
      switch call.method {
      case "state": result(controls.state)
      case "discover": controls.discover { result($0) }
      case "installDriver":
        NakuVirtualAudioDriver.openInstaller { error in
          if let error { result(FlutterError(code: "driver_install", message: error.localizedDescription, details: nil)) }
          else { result(controls.state) }
        }
      case "testDriver":
        controls.testDriver { value, error in
          if let error { result(FlutterError(code: "driver_test", message: error.localizedDescription, details: nil)) }
          else { result(value) }
        }
      case "setVolume":
        guard let args = call.arguments as? [String: Any], let value = args["volume"] as? NSNumber else {
          result(FlutterError(code: "invalid", message: "请指定 HomePod 音量。", details: nil)); return
        }
        controls.setReceiverVolume(value.doubleValue) { error in
          if let error { result(FlutterError(code: "homepod_volume", message: error.localizedDescription, details: nil)) }
          else { result(controls.state) }
        }
      case "enable":
        guard let args = call.arguments as? [String: Any], let id = args["id"] as? String else {
          result(FlutterError(code: "invalid", message: "请选择 HomePod。", details: nil)); return
        }
        let latency = (args["latencyMs"] as? NSNumber)?.intValue ?? 120
        controls.enable(id: id, requestedLatency: latency) { error in
          if let error {
            let code: String
            switch error {
            case NakuVirtualAudioError.driverRequired: code = "driver_required"
            case NakuVirtualAudioError.authorizationRequired: code = "driver_update_required"
            default: code = "homepod_audio"
            }
            result(FlutterError(code: code, message: error.localizedDescription, details: nil))
          } else { result(controls.state) }
        }
      case "disable": controls.disable(); result(controls.state)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
#endif
}
