import Foundation
import Darwin

/// Reconstructed from Unisson 0.1.3's observed packet loop (0x10010c880).
/// Deadlines derive from total samples, never from repeated relative sleeps.
struct NakuAirPlayAudioClock {
    static let sampleRate = 44100.0
    static let frames = 352
    static let lateThreshold = 0.005, resetThreshold = 0.250
    private(set) var frameCount: UInt64 = 0
    private var epochFrame: UInt64 = 0
    private var epochTicks: UInt64
    private var epochWall: Double
    let ticksPerSecond: Double

    init(ticks: UInt64, wall: Double, ticksPerSecond: Double) {
        epochTicks = ticks; epochWall = wall; self.ticksPerSecond = ticksPerSecond
    }
    var deadline: UInt64 {
        epochTicks &+ UInt64(Double(frameCount-epochFrame)/Self.sampleRate*ticksPerSecond)
    }
    var syncWall: Double { epochWall+Double(frameCount-epochFrame)/Self.sampleRate }
    mutating func observeWake(ticks: UInt64, wall: Double) -> (lateness: Double, reset: Bool) {
        let due = deadline
        let late = ticks > due ? Double(ticks-due)/ticksPerSecond : 0
        if late > Self.resetThreshold {
            // Preserve contiguous RTP samples and re-anchor their NTP mapping,
            // as the reference does after a >250 ms scheduling interruption.
            epochFrame = frameCount; epochTicks = ticks; epochWall = wall
            return (late, true)
        }
        return (late, false)
    }
    mutating func advance() { frameCount &+= UInt64(Self.frames) }
}

/// One producer/consumer sample clock, confined by the sender's state lock.
/// REA: source pull 0x1000c7b40, PI controller 0x1000c801c, 48-tap/512-phase
/// Kaiser-windowed sinc 0x1000c86a8 and interpolation 0x1000c812c.
final class NakuAirPlayDriftBuffer {
    struct Configuration {
        let targetMs: Double, maximumMs: Double, maxCorrectionPPM: Double
    }
    static let capacity = 8192, taps = 48, phases = 512
    private static let rate = NakuAirPlayAudioClock.sampleRate
    private let configuration: Configuration
    private var samples = [Float](repeating: 0, count: capacity*2)
    private var writeFrame = 0
    private var position = 0.0
    private var priming = true
    private var filteredDepth: Double, integral = 0.0
    private(set) var ratio = 1.0
    private(set) var underruns: UInt64 = 0, droppedFrames: UInt64 = 0

    init(configuration: Configuration) {
        self.configuration = configuration
        filteredDepth = configuration.targetMs*Self.rate/1000
    }
    var bufferedFrames: Int { max(0, Int(Double(writeFrame)-position)) }
    var driftPPM: Double { (ratio-1)*1_000_000 }
    var isPriming: Bool { priming }
    static func prepare() { _ = kernel }

    func reset(clearCounters: Bool = false) {
        writeFrame = 0; position = 0; priming = true; ratio = 1; integral = 0
        filteredDepth = configuration.targetMs*Self.rate/1000
        if clearCounters { underruns = 0; droppedFrames = 0 }
    }

    func append(_ pcm: Data) {
        let frames = pcm.count/4
        guard frames > 0 else { return }
        // Retain filter history as well as unread samples. An oversized write
        // keeps its newest bounded window without allocating an oversized queue.
        let keep = min(frames, Self.capacity)
        let first = frames-keep
        pcm.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for frame in first..<frames {
                let slot = ((writeFrame+frame)%Self.capacity)*2
                for channel in 0..<2 {
                    let value = Int16(littleEndian: raw.loadUnaligned(fromByteOffset: frame*4+channel*2, as: Int16.self))
                    samples[slot+channel] = Float(value)/32768
                }
            }
        }
        writeFrame += frames
        let oldest = max(0, writeFrame-Self.capacity+23)
        if position < Double(oldest) {
            droppedFrames &+= UInt64(Double(oldest)-position)
            position = Double(oldest); priming = true
        }
    }

    func read(lateness: Double = 0) -> Data {
        let count = NakuAirPlayAudioClock.frames
        let period = Double(count)/Self.rate
        let target = configuration.targetMs*Self.rate/1000
        var depth = Double(writeFrame)-position
        // The reference allows the measured sender lateness before classifying
        // an overrun, then trims stale input back toward its configured target.
        let lateFrames = max(0, lateness)*Self.rate
        if depth > configuration.maximumMs*Self.rate/1000+lateFrames {
            let drop = max(0, Int(depth-target-lateFrames))
            position += Double(drop); droppedFrames &+= UInt64(drop)
            depth = Double(writeFrame)-position
        }
        if priming {
            guard depth >= target else { return Data(repeating: 0, count: count*4) }
            priming = false; filteredDepth = depth
        }
        // The one-second queue filter and PI gains come from the reference.
        filteredDepth += (1-exp(-period))*(depth-filteredDepth)
        let error = (filteredDepth-target)/Self.rate
        let proposedIntegral = integral+period*error
        let limit = configuration.maxCorrectionPPM*1e-6
        var correction = error*0.05+proposedIntegral*0.002
        if abs(correction) < limit { integral = proposedIntegral }
        else { correction = error*0.05+integral*0.002 }
        ratio = 1+min(limit, max(-limit, correction))

        let end = Int(position+ratio*Double(count-1))+24
        guard end < writeFrame else {
            priming = true; underruns &+= 1
            return Data(repeating: 0, count: count*4)
        }
        var output = Data(count: count*4)
        let coefficients = Self.kernel
        output.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            samples.withUnsafeBufferPointer { input in
                coefficients.withUnsafeBufferPointer { table in
                    for frame in 0..<count {
                        let center = Int(position)
                        let phase = (position-Double(center))*Double(Self.phases)
                        let row = min(Self.phases-1, Int(phase))
                        let fraction = Float(phase-Double(row))
                        var left0: Float = 0, left1: Float = 0, right0: Float = 0, right1: Float = 0
                        for tap in 0..<Self.taps {
                            let source = center-23+tap
                            if source < 0 { continue }
                            let slot = (source%Self.capacity)*2
                            let a = table[row*Self.taps+tap], b = table[(row+1)*Self.taps+tap]
                            left0 += input[slot]*a; left1 += input[slot]*b
                            right0 += input[slot+1]*a; right1 += input[slot+1]*b
                        }
                        let left = Int16(min(32767, max(-32768, ((left0+(left1-left0)*fraction)*32768).rounded())))
                        let right = Int16(min(32767, max(-32768, ((right0+(right1-right0)*fraction)*32768).rounded())))
                        raw.storeBytes(of: left.littleEndian, toByteOffset: frame*4, as: Int16.self)
                        raw.storeBytes(of: right.littleEndian, toByteOffset: frame*4+2, as: Int16.self)
                        position += ratio
                    }
                }
            }
        }
        return output
    }

    private static let kernel: [Float] = {
        func bessel0(_ value: Double) -> Double {
            var sum = 1.0, term = 1.0
            for order in 1...64 {
                let factor = value/(2*Double(order))
                term *= factor*factor; sum += term
                if term <= sum*1e-12 { break }
            }
            return sum
        }
        let normalization = bessel0(9)
        var result = [Float](repeating: 0, count: (phases+1)*taps)
        for phase in 0...phases {
            var row = [Double](repeating: 0, count: taps), sum = 0.0
            for tap in 0..<taps {
                let x = Double(tap)-23-Double(phase)/Double(phases)
                let sinc = abs(x) < 1e-12 ? 0.96 : sin(.pi*0.96*x)/(.pi*x)
                let radius = x/24
                let window = abs(radius) < 1 ? bessel0(9*sqrt(1-radius*radius))/normalization : 0
                row[tap] = sinc*window; sum += row[tap]
            }
            for tap in 0..<taps { result[phase*taps+tap] = Float(row[tap]/sum) }
        }
        return result
    }()
}
