import Foundation

func runHomePodAudioClockTests() throws {
    func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw NakuAirPlayError.invalid("Audio clock test: "+message) }
    }
    let frames = NakuAirPlayAudioClock.frames
    var clock = NakuAirPlayAudioClock(ticks: 10_000, wall: 1_700_000_000, ticksPerSecond: 1e9)
    for _ in 0..<126 { clock.advance() }
    let expected = UInt64(Double(frames*126)/44100*1e9)+10_000
    try require(clock.deadline == expected, "deadline derives from total samples")
    let before = clock.frameCount
    let ordinary = clock.observeWake(ticks: clock.deadline+6_000_000, wall: 1_700_000_001)
    try require(!ordinary.reset && ordinary.lateness > NakuAirPlayAudioClock.lateThreshold,
                "5 ms lateness is observable without resetting RTP")
    let boundary = clock.observeWake(ticks: clock.deadline+250_000_000, wall: 1_700_000_001.5)
    try require(!boundary.reset, "exactly 250 ms keeps the reference's strict reset boundary")
    let resume = clock.deadline+300_000_000
    let recovered = clock.observeWake(ticks: resume, wall: 1_700_000_002)
    try require(recovered.reset && clock.deadline == resume && clock.frameCount == before && clock.syncWall == 1_700_000_002,
                "250 ms interruption reanchors NTP and deadlines, preserving contiguous RTP")
    clock.advance()
    try require(abs(clock.syncWall-(1_700_000_002+Double(frames)/44100)) < 1e-6,
                "post-recovery synchronization follows the same sample clock")

    let configuration = NakuAirPlayDriftBuffer.Configuration(targetMs: 15, maximumMs: 40, maxCorrectionPPM: 1000)
    func pcm(_ count: Int, left: Int16 = 8192, right: Int16 = -4096) -> Data {
        var result = Data(count: count*4)
        result.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            for frame in 0..<count {
                raw.storeBytes(of: left.littleEndian, toByteOffset: frame*4, as: Int16.self)
                raw.storeBytes(of: right.littleEndian, toByteOffset: frame*4+2, as: Int16.self)
            }
        }
        return result
    }
    NakuAirPlayDriftBuffer.prepare()
    let buffer = NakuAirPlayDriftBuffer(configuration: configuration)
    buffer.append(pcm(100))
    try require(buffer.read() == Data(repeating: 0, count: frames*4) && buffer.bufferedFrames == 100,
                "priming preserves incomplete source data")
    buffer.append(pcm(800))
    let first = buffer.read()
    try require(!buffer.isPriming && first.count == frames*4, "buffer starts only with configured headroom")
    try first.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
        for frame in 48..<frames {
            let left = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: frame*4, as: Int16.self)))
            let right = Int(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: frame*4+2, as: Int16.self)))
            try require(abs(left-8192) <= 2 && abs(right+4096) <= 2, "FIR DC gain and stereo isolation")
        }
    }
    for _ in 0..<8 { _ = buffer.read() }
    try require(buffer.underruns == 1 && buffer.isPriming, "one starvation episode returns to priming")
    buffer.append(pcm(900)); _ = buffer.read()
    try require(!buffer.isPriming, "starved source resumes with headroom")
    buffer.append(pcm(NakuAirPlayDriftBuffer.capacity*3))
    try require(buffer.bufferedFrames <= NakuAirPlayDriftBuffer.capacity && buffer.droppedFrames > 0,
                "large producer writes remain bounded and observable")
    _ = buffer.read()
    try require(buffer.bufferedFrames < Int(40*44.1), "overrun drops stale samples toward target")
    buffer.reset()
    try require(buffer.bufferedFrames == 0 && buffer.driftPPM == 0 && buffer.isPriming, "flush resets sample phase and controller")

    // Exercise the actual FIR/PI consumer against a deterministic source clock,
    // with fixed 352-frame deadlines and source clocks 300 ppm faster/slower.
    for ppm in [-300.0, 300.0] {
        let drift = NakuAirPlayDriftBuffer(configuration: configuration)
        drift.append(pcm(662))
        var fractional = 0.0
        for _ in 0..<15_000 {
            _ = drift.read()
            fractional += Double(frames)*(1+ppm*1e-6)
            let incoming = Int(fractional); fractional -= Double(incoming)
            drift.append(pcm(incoming))
        }
        try require(drift.underruns == 0 && drift.droppedFrames == 0 && abs(drift.driftPPM) <= 1000.001,
                    "bounded drift correction avoids periodic starvation or overruns")
        try require(abs(drift.driftPPM-ppm) < 100, "controller follows the source clock instead of repeatedly dropping packets")
        print("PASS source clock \(ppm) ppm -> correction \(drift.driftPPM) ppm, queue \(drift.bufferedFrames) frames")
    }
    print("PASS absolute deadlines, 5/250 ms timing boundaries, NTP reanchor, FIR stereo/DC gain, priming/underrun/overrun/reset, continuous source-clock drift")
}
