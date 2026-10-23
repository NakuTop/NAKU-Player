import Foundation
import AVFoundation
import CoreVideo

// Two tiny, valid H.264 files for the loopback download and native playback
// regression. Generated locally; no user video is changed or uploaded.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for episode in 1...2 {
    let url = output.appendingPathComponent("episode-\(episode).mp4")
    let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: 320,
        AVVideoHeightKey: 180
    ])
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 320,
        kCVPixelBufferHeightKey as String: 180
    ]
    let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
    writer.add(input)
    guard writer.startWriting() else { throw writer.error! }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<48 {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.002) }
        var pixel: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32ARGB, attributes as CFDictionary, &pixel) == kCVReturnSuccess,
              let pixel = pixel else { fatalError("Pixel buffer allocation failed") }
        CVPixelBufferLockBaseAddress(pixel, [])
        let address = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<180 {
            for x in 0..<320 {
                let offset = y * stride + x * 4
                address[offset] = 255
                address[offset + 1] = UInt8(episode == 1 ? 180 : frame * 4)
                address[offset + 2] = UInt8(episode == 2 ? 180 : frame * 4)
                address[offset + 3] = UInt8((x + y + frame) % 256)
            }
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        guard adapter.append(pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else {
            throw writer.error!
        }
    }
    input.markAsFinished()
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw writer.error! }
    print(url.path)
}
