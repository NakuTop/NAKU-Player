import Foundation
import CoreAudio
import AVFoundation

enum NakuPCMTapError: LocalizedError {
  case format
  case conversion(String)

  var errorDescription: String? {
    switch self {
    case .format: return "当前系统音频格式无法转换为 HomePod 立体声音频。"
    case let .conversion(message): return "系统音频转换失败：\(message)"
    }
  }
}

/// Stateful converter used on one serial queue, never on the Core Audio IO thread.
/// Its output is stereo 44.1 kHz interleaved signed 16-bit little-endian PCM.
final class NakuPCMConverter {
  let inputFormat: AVAudioFormat
  let outputFormat: AVAudioFormat
  private let converter: AVAudioConverter

  init(inputFormat: AVAudioFormat) throws {
    guard inputFormat.sampleRate.isFinite, (8000...192000).contains(inputFormat.sampleRate),
          inputFormat.channelCount == 2,
          inputFormat.commonFormat == .pcmFormatFloat32,
          let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100,
                                    channels: 2, interleaved: true),
          let converter = AVAudioConverter(from: inputFormat, to: output) else {
      throw NakuPCMTapError.format
    }
    self.inputFormat = inputFormat
    self.outputFormat = output
    self.converter = converter
  }

  func convert(_ input: AVAudioPCMBuffer) throws -> Data {
    guard input.format == inputFormat, input.frameLength <= 8192 else {
      throw NakuPCMTapError.format
    }
    return try perform(input, finishing: false)
  }

  /// Flushes the rate-converter tail for deterministic fixtures, not after every IO block.
  func finish() throws -> Data { try perform(nil, finishing: true) }

  private func perform(_ input: AVAudioPCMBuffer?, finishing: Bool) throws -> Data {
    var supplied = false
    var result = Data()
    // A bounded loop also protects against an unexpected converter that never yields.
    for _ in 0..<8 {
      let inputFrames = Double(input?.frameLength ?? 1024)
      let capacity = AVAudioFrameCount(ceil(inputFrames * 44100 / inputFormat.sampleRate) + 512)
      guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
        throw NakuPCMTapError.format
      }
      var error: NSError?
      let status = converter.convert(to: output, error: &error) { _, state in
        if let input, !supplied {
          supplied = true
          state.pointee = .haveData
          return input
        }
        state.pointee = finishing ? .endOfStream : .noDataNow
        return nil
      }
      if status == .error { throw NakuPCMTapError.conversion(error?.localizedDescription ?? "未知错误") }
      if output.frameLength > 0 {
        let buffers = UnsafeMutableAudioBufferListPointer(output.mutableAudioBufferList)
        guard let bytes = buffers.first?.mData else { throw NakuPCMTapError.format }
        result.append(bytes.assumingMemoryBound(to: UInt8.self), count: Int(output.frameLength) * 4)
      }
      if status == .inputRanDry || status == .endOfStream || output.frameLength == 0 { return result }
    }
    throw NakuPCMTapError.conversion("转换器未能在有界输出窗口内结束")
  }
}

