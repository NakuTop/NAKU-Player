import Cocoa
#if canImport(FlutterMacOS)
import FlutterMacOS
#endif
import Vision
import Speech
import AVFoundation

/// Works only on decoded media supplied by the player. Never records a microphone
/// or sends audio, frames or dialogue to a remote service.
final class NakuSubtitleTools {
  #if canImport(FlutterMacOS)
  private static var recognitionTasks: [String: Task<Void, Never>] = [:]
  static func register(with messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(name: "naku/subtitle-tools", binaryMessenger: messenger)
    channel.setMethodCallHandler { call, result in
      if call.method == "cancelRecognition", let id = call.arguments as? String {
        recognitionTasks.removeValue(forKey: id)?.cancel()
        result(nil); return
      }
      if call.method == "transcribeClip" {
        guard #available(macOS 26.0, *), SpeechTranscriber.isAvailable,
              let args = call.arguments as? [String: Any],
              let pcm = args["pcm"] as? FlutterStandardTypedData,
              pcm.data.count >= 640, pcm.data.count <= 640000,
              let id = args["id"] as? String, id.count <= 100 else {
          result(FlutterError(code: "unavailable", message: "本地文字匹配需要支持语音识别的 macOS 26 或更高版本", details: nil)); return
        }
        recognitionTasks[id]?.cancel()
        recognitionTasks[id] = Task {
          do {
            let words = try await transcribeClip(pcm.data, locale: args["locale"] as? String ?? "en-US")
            try Task.checkCancellation()
            result(words)
          } catch {
            result(FlutterError(code: "recognition", message: "本地对白文字识别未完成", details: nil))
          }
          recognitionTasks.removeValue(forKey: id)
        }
        return
      }
      guard let args = call.arguments as? FlutterStandardTypedData,
            args.data.count <= 16 * 1024 * 1024 else {
        result(FlutterError(code: "input", message: "分析片段无效或过大", details: nil)); return
      }
      let data = args.data
      DispatchQueue.global(qos: .utility).async {
        do {
          let output: Any
          switch call.method {
          case "voiceActivity": output = FlutterStandardTypedData(bytes: try voiceActivity(data))
          case "hasChineseCaption": output = try hasChineseCaption(data)
          default:
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }; return
          }
          DispatchQueue.main.async { result(output) }
        } catch {
          DispatchQueue.main.async { result(FlutterError(code: "analysis", message: "本地字幕分析未完成", details: nil)) }
        }
      }
    }
  }

  #endif

  /// On-device, file-only recognition. No microphone or remote speech API.
  @available(macOS 26.0, *)
  static func transcribeClip(_ pcm: Data, locale language: String) async throws -> [[String: Any]] {
    guard SpeechTranscriber.isAvailable,
          let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: language)) else {
      throw NSError(domain: "Speech", code: 1)
    }
    let module = SpeechTranscriber(locale: locale, transcriptionOptions: [],
      reportingOptions: [], attributeOptions: [.audioTimeRange, .transcriptionConfidence])
    if let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
      try await request.downloadAndInstall()
    }
    try Task.checkCancellation()
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("naku-dialogue-\(UUID().uuidString).wav")
    defer { try? FileManager.default.removeItem(at: url) }
    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let frames = min(320000, pcm.count / 2)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    buffer.frameLength = AVAudioFrameCount(frames)
    pcm.withUnsafeBytes { raw in
      for i in 0..<frames {
        let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 2, as: Int16.self))
        buffer.floatChannelData![0][i] = Float(value) / 32768
      }
    }
    do {
      let output = try AVAudioFile(forWriting: url, settings: format.settings)
      try output.write(from: buffer)
    }
    let file = try AVAudioFile(forReading: url)
    let analyzer = SpeechAnalyzer(modules: [module])
    let collector = Task { () throws -> [[String: Any]] in
      var words = [[String: Any]]()
      for try await result in module.results {
        for run in result.text.runs {
          guard let range = run.audioTimeRange else { continue }
          words.append(["text": String(result.text[run.range].characters),
            "start": range.start.seconds, "end": CMTimeRangeGetEnd(range).seconds,
            "confidence": run.transcriptionConfidence ?? 0])
        }
      }
      return words
    }
    return try await withTaskCancellationHandler(operation: {
      do {
        if let end = try await analyzer.analyzeSequence(from: file) {
          try await analyzer.finalizeAndFinish(through: end)
        } else { await analyzer.cancelAndFinishNow() }
        return try await collector.value
      } catch {
        collector.cancel()
        await analyzer.cancelAndFinishNow()
        throw error
      }
    }, onCancel: {
      collector.cancel()
      Task { await analyzer.cancelAndFinishNow() }
    })
  }

  static func voiceActivity(_ data: Data) throws -> Data {
    guard data.count >= 640, let vad = fvad_new() else { throw NSError(domain: "VAD", code: 1) }
    defer { fvad_free(vad) }
    guard fvad_set_sample_rate(vad, 16000) == 0, fvad_set_mode(vad, 2) == 0 else {
      throw NSError(domain: "VAD", code: 2)
    }
    // Copy to aligned storage; method-channel bytes have no Int16 alignment guarantee.
    var samples = [Int16](repeating: 0, count: data.count / 2)
    _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0) }
    var output = Data(capacity: samples.count / 320)
    samples.withUnsafeBufferPointer { buffer in
      for start in stride(from: 0, through: samples.count - 320, by: 320) {
        output.append(fvad_process(vad, buffer.baseAddress! + start, 320) == 1 ? 1 : 0)
      }
    }
    return output
  }

  static func hasChineseCaption(_ data: Data) throws -> Bool {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]
    request.usesLanguageCorrection = false
    // Bottom 45% only; ignore logos and most titles.
    request.regionOfInterest = CGRect(x: 0.08, y: 0.02, width: 0.84, height: 0.43)
    try VNImageRequestHandler(data: data).perform([request])
    return (request.results ?? []).contains { observation in
      guard let text = observation.topCandidates(1).first, text.confidence >= 0.65 else { return false }
      return text.string.unicodeScalars.filter { (0x3400...0x9FFF).contains(Int($0.value)) }.count >= 3
    }
  }
}
