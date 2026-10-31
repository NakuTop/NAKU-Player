import Foundation
import AVFoundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
  if !condition() { fatalError(message) }
}

func fixture(rate: Double, interleaved: Bool, chunks: [Int]) throws -> [Int16] {
  let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate,
                            channels: 2, interleaved: interleaved)!
  let converter = try NakuPCMConverter(inputFormat: format)
  var bytes = Data(), offset = 0, chunkIndex = 0
  let total = Int(rate)
  while offset < total {
    let frames = min(total - offset, chunks[chunkIndex % chunks.count])
    let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
    input.frameLength = AVAudioFrameCount(frames)
    let channels = input.floatChannelData!
    for i in 0..<frames {
      let signal = Float(sin(2 * Double.pi * 1000 * Double(offset + i) / rate))
      if interleaved {
        channels[0][2 * i] = 0.5 * signal
        channels[0][2 * i + 1] = -0.25 * signal
      } else {
        channels[0][i] = 0.5 * signal
        channels[1][i] = -0.25 * signal
      }
    }
    bytes.append(try converter.convert(input))
    offset += frames; chunkIndex += 1
  }
  bytes.append(try converter.finish())
  expect(bytes.count % 4 == 0, "stereo frames must contain 4 bytes")
  let samples: [Int16] = bytes.withUnsafeBytes { raw in
    (0..<raw.count / 2).map { Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) }
  }
  let frames = samples.count / 2
  expect(abs(frames - 44100) <= 2, "wrong resampled count: \(frames) at \(rate)")
  var signalEnergy = 0.0, errorEnergy = 0.0
  // Exclude resampler boundary transients from the independent sine oracle.
  for i in 128..<(frames - 128) {
    let expected = 0.5 * sin(2 * Double.pi * 1000 * Double(i) / 44100)
    let actual = Double(samples[2 * i]) / 32768
    let right = Double(samples[2 * i + 1]) / 32768
    signalEnergy += actual * actual
    errorEnergy += (actual - expected) * (actual - expected)
    expect(abs(right + actual / 2) < 0.0001, "channel layout or stereo polarity damaged")
  }
  expect(signalEnergy / Double(frames - 256) > 0.12, "converted signal unexpectedly silent")
  expect(sqrt(errorEnergy / Double(frames - 256)) < 0.002, "rate conversion has incorrect phase or contents")
  print("PASS \(rate) Hz \(interleaved ? "interleaved" : "planar") -> \(frames) stereo frames")
  return samples
}

let fixed = try fixture(rate: 44100, interleaved: true, chunks: [441])
let planar = try fixture(rate: 44100, interleaved: false, chunks: [1, 127, 512, 2048])
expect(fixed == planar, "planar/interleaved or chunk boundaries alter same-rate PCM")
let resampled = try fixture(rate: 48000, interleaved: false, chunks: [480])
let variable = try fixture(rate: 48000, interleaved: true, chunks: [1, 31, 256, 1024, 2048])
expect(resampled.count == variable.count, "resampled count depends on callback size")
let worst = zip(resampled, variable).map { abs(Int($0) - Int($1)) }.max() ?? 0
expect(worst <= 1, "resampling differs by callback layout/size: \(worst)")
let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
do {
  _ = try NakuPCMConverter(inputFormat: mono)
  fatalError("unsupported channel format must be rejected")
} catch NakuPCMTapError.format { print("PASS unsupported format rejected") }
let unstarted = NakuVirtualAudioCapture { _ in fatalError("unstarted driver reader emitted audio") }
unstarted.stop(); unstarted.stop()
print("PASS unstarted stop is idempotent; no capture or hardware API started")
