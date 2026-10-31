import AppKit
import AVFoundation
import CoreAudio
import Foundation
import Security

enum NakuAudioLog {
  private static let queue = DispatchQueue(label: "naku.audio.diagnostics")
  static func write(_ format: String, _ arguments: CVarArg...) {
    let message = String(format: format, arguments: arguments)
    NSLog("%@", message)
    queue.async {
      guard let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
      let url = cache.appendingPathComponent("NAKUAudioDiagnostics.log")
      let line = "\(Date().timeIntervalSince1970) \(message)\n"
      guard let data = line.data(using: .utf8) else { return }
      try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
      let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
      if size > 131072 || !FileManager.default.fileExists(atPath: url.path) { try? Data().write(to: url) }
      guard let handle = try? FileHandle(forWritingTo: url) else { return }
      defer { try? handle.close() }
      _ = try? handle.seekToEnd(); try? handle.write(contentsOf: data)
    }
  }
}

enum NakuVirtualAudioError: LocalizedError {
  case driverRequired, authorizationRequired, hardware(String, OSStatus), unavailable(String)
  var errorDescription: String? {
    switch self {
    case .driverRequired: return "首次开启需要安装 NAKU 专用虚拟声卡。"
    case .authorizationRequired: return "请更新 NAKU 虚拟声卡授权，以允许当前版本连接。"
    case let .hardware(action, status): return "\(action)失败（\(status)）。已尝试恢复原音频输出。"
    case let .unavailable(message): return message
    }
  }
}

enum NakuVirtualAudioDriver {
  static let uid = "com.shenminghao.naku.virtualaudio.v1"
  static let leaseKey = "naku.homepod.virtualAudioInterruptedRoute"
  private static let authorizationURL = URL(fileURLWithPath: "/Library/Application Support/NAKUAudio/authorization.plist")

  static func devices() -> [AudioDeviceID] {
    var p = property(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &p, 0, nil, &size) == noErr,
          size >= MemoryLayout<AudioDeviceID>.size, size <= 65536 else { return [] }
    var values = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    let status = values.withUnsafeMutableBytes {
      AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &p, 0, nil, &size, $0.baseAddress!)
    }
    return status == noErr ? Array(values.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size)) : []
  }

  static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                              mElement: kAudioObjectPropertyElementMain)
  }

  static func deviceUID(_ device: AudioDeviceID) -> String? {
    guard device != kAudioObjectUnknown else { return nil }
    var p = property(kAudioDevicePropertyDeviceUID)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &p, 0, nil, &size, &value) == noErr else { return nil }
    return value?.takeRetainedValue() as String?
  }

  static func device(_ uid: String) -> AudioDeviceID? {
    devices().first { deviceUID($0) == uid }
  }

  static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
    var p = property(selector), value = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &p, 0, nil, &size, &value)
    return value
  }

  static func setDefault(_ selector: AudioObjectPropertySelector, _ device: AudioDeviceID) throws {
    var p = property(selector), value = device
    let status = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &p, 0, nil,
                                            UInt32(MemoryLayout<AudioDeviceID>.size), &value)
    guard status == noErr else { throw NakuVirtualAudioError.hardware("切换音频输出", status) }
  }

  static var installed: Bool { device(uid) != nil }

  private static var driverStatus: [String: Any]? {
    let url = URL(fileURLWithPath: "/Library/Application Support/NAKUAudio/driver-status.plist")
    guard let data = try? Data(contentsOf: url),
          let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          (value["version"] as? NSNumber)?.intValue == 1 else { return nil }
    return value
  }

  static var ready: Bool { driverStatus?["driverReady"] as? Bool == true }

  static var authorized: Bool {
    guard let data = try? Data(contentsOf: authorizationURL),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let text = plist["requirement"] as? String,
          (plist["ownerUID"] as? NSNumber)?.uint32Value == getuid() else { return false }
    var requirement: SecRequirement?, code: SecCode?
    guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
          SecCodeCopySelf([], &code) == errSecSuccess, let requirement, let code else { return false }
    return SecCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), requirement) == errSecSuccess
  }

  static var state: [String: Any] {
    let present = installed, allowed = present && authorized
    return ["driverInstalled": present, "driverName": "NAKU 虚拟声卡",
            "needsDriverUpdate": present && !allowed,
            "driverInstallStatus": allowed && ready ? "ready" : "idle"]
  }

  static func openInstaller(completion: @escaping (Error?) -> Void) {
    guard Bundle.main.bundleURL.deletingLastPathComponent().path == "/Applications" else {
      completion(NakuVirtualAudioError.unavailable("请先将 NAKU 放入“应用程序”文件夹，再安装专用驱动。")); return
    }
    let reusable = installed && driverStatus != nil && FileManager.default.isExecutableFile(
      atPath: "/Library/PrivilegedHelperTools/com.shenminghao.naku.audio-broker")
    let resource = reusable ? "NAKUAudioAuthorization" : "NAKUAudio"
    guard let package = Bundle.main.url(forResource: resource, withExtension: "pkg") else {
      completion(NakuVirtualAudioError.unavailable("当前版本未包含专用驱动安装器。")); return
    }
    // The package is a sealed resource of this exact app build, with no remote
    // executable download or privileged command service in the player.
    var own: SecStaticCode?
    guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &own) == errSecSuccess,
          let own, SecStaticCodeCheckValidity(own, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess else {
      completion(NakuVirtualAudioError.unavailable("NAKU 安装包校验失败，请重新安装播放器。")); return
    }
    NSWorkspace.shared.open([package], withApplicationAt: URL(fileURLWithPath: "/System/Library/CoreServices/Installer.app"),
                            configuration: NSWorkspace.OpenConfiguration()) { _, error in
      DispatchQueue.main.async { completion(error) }
    }
  }

  static func restore(_ previous: [String: String]) {
    for (selector, key) in [(kAudioHardwarePropertyDefaultOutputDevice, "output"),
                            (kAudioHardwarePropertyDefaultSystemOutputDevice, "system")] {
      guard deviceUID(defaultDevice(selector)) == uid else { continue }
      let prior = previous[key].flatMap(device) ?? physicalFallback()
      if let prior { try? setDefault(selector, prior) }
    }
    // A manual change by the user wins over the old route. Keep a recovery
    // record only if no physical output was available to replace our device.
    if deviceUID(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)) != uid &&
        deviceUID(defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)) != uid {
      UserDefaults.standard.removeObject(forKey: leaseKey)
    }
  }

  private static func physicalFallback() -> AudioDeviceID? {
    devices().first { id in
      var p = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceCanBeDefaultDevice,
        mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
      var canOutput: UInt32 = 0, size: UInt32 = 4
      guard AudioObjectGetPropertyData(id, &p, 0, nil, &size, &canOutput) == noErr, canOutput != 0 else { return false }
      p = property(kAudioDevicePropertyTransportType)
      var transport: UInt32 = 0
      return AudioObjectGetPropertyData(id, &p, 0, nil, &size, &transport) == noErr && transport != kAudioDeviceTransportTypeVirtual
    }
  }

  static func recoverInterruptedRoute() {
    guard let previous = UserDefaults.standard.dictionary(forKey: leaseKey) as? [String: String] else { return }
    restore(previous)
  }
}

/// Reads only NAKU's explicitly selected OUTPUT driver's memory, never a HAL
/// input. The private broker arms restoration before any default-device change.
final class NakuVirtualAudioCapture {
  private let queue = DispatchQueue(label: "naku.virtual-audio.reader", qos: .userInteractive)
  private let queueKey = DispatchSpecificKey<Bool>()
  private let onPCM: (Data) -> Void
  var onError: ((Error) -> Void)?
  private var reader: OpaquePointer?
  private var timer: DispatchSourceTimer?
  private var converter: NakuPCMConverter?
  private var previous: [String: String] = [:]
  private var scratch: AVAudioPCMBuffer?
  private(set) var droppedFrames: UInt64 = 0

  init(onPCM: @escaping (Data) -> Void) {
    self.onPCM = onPCM; queue.setSpecific(key: queueKey, value: true)
  }
  deinit { stop() }
  private func serial<T>(_ body: () throws -> T) rethrows -> T {
    if DispatchQueue.getSpecific(key: queueKey) == true { return try body() }
    return try queue.sync(execute: body)
  }
  func start() throws {
    try serial {
      guard self.reader == nil else { return }
      do { try self.startAvailable() } catch { self.stopAvailable(); throw error }
    }
  }
  func stop() { serial { self.stopAvailable() } }

  private func startAvailable() throws {
    guard let virtual = NakuVirtualAudioDriver.device(NakuVirtualAudioDriver.uid) else { throw NakuVirtualAudioError.driverRequired }
    let output = NakuVirtualAudioDriver.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    let system = NakuVirtualAudioDriver.defaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice)
    guard let outputUID = NakuVirtualAudioDriver.deviceUID(output), outputUID != NakuVirtualAudioDriver.uid else {
      throw NakuVirtualAudioError.unavailable("请先在系统声音设置中选择电脑扬声器，再开启 HomePod 输出。")
    }
    var error = [CChar](repeating: 0, count: 512), code: Int32 = 0
    guard let connection = NAKUAudioReaderOpen(&error, error.count, &code) else {
      if code == 2 { throw NakuVirtualAudioError.authorizationRequired }
      throw NakuVirtualAudioError.unavailable("无法连接 NAKU 虚拟声卡服务：\(String(cString: error))")
    }
    reader = connection
    guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true),
          let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2048) else { throw NakuPCMTapError.format }
    converter = try NakuPCMConverter(inputFormat: format); scratch = buffer
    let systemUID = NakuVirtualAudioDriver.deviceUID(system)
    previous = ["output": outputUID, "system": systemUID == NakuVirtualAudioDriver.uid ? outputUID : systemUID ?? outputUID]
    let armed = outputUID.withCString { output in
      (previous["system"] ?? "").withCString { system in
        NAKUAudioReaderArm(connection, output, system, &error, error.count)
      }
    }
    guard armed else { throw NakuVirtualAudioError.unavailable("无法准备音频输出恢复：\(String(cString: error))") }
    UserDefaults.standard.set(previous, forKey: NakuVirtualAudioDriver.leaseKey)
    try NakuVirtualAudioDriver.setDefault(kAudioHardwarePropertyDefaultOutputDevice, virtual)
    try NakuVirtualAudioDriver.setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, virtual)
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .milliseconds(2), leeway: .milliseconds(1))
    timer.setEventHandler { [weak self] in self?.drain() }
    self.timer = timer; timer.resume()
  }

  private func drain() {
    guard let reader, let scratch, let converter else { return }
    do {
      guard NAKUAudioReaderIsConnected(reader) else { throw NakuVirtualAudioError.unavailable("NAKU 虚拟声卡连接已中断。") }
      for _ in 0..<8 {
        let count = NAKUAudioReaderRead(reader, scratch.floatChannelData![0], Int(scratch.frameCapacity), &droppedFrames)
        if count == 0 { break }
        scratch.frameLength = AVAudioFrameCount(count)
        let data = try converter.convert(scratch)
        if !data.isEmpty { onPCM(data) }
      }
    } catch {
      stopAvailable(); onError?(error)
    }
  }

  private func stopAvailable() {
    timer?.cancel(); timer = nil
    if !previous.isEmpty { NakuVirtualAudioDriver.restore(previous); previous = [:] }
    if let reader { NAKUAudioReaderClose(reader) }
    reader = nil; converter = nil; scratch = nil
  }
}
