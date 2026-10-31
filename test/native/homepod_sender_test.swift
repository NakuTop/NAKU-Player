import Foundation

@main struct Probe {
    static func main() {
        do {
            let args = CommandLine.arguments
            if args.contains("--self-test") { try NakuAirPlaySender.selfTest(); return }
            guard args.count >= 3, let duration = Double(args[2]), (0.1...10).contains(duration) else { print("Usage: naku-homepod-probe <numericIPv4> <durationSeconds 0.1...10> [latencyMs] | --self-test"); exit(2) }
            let sender = NakuAirPlaySender(address: args[1], latencyMs: args.count > 3 ? Int(args[3]) ?? 120 : 120)
            defer { sender.close() }
            try sender.connect()
            print("connected configuredLatencyMs=\(sender.configuredLatencyMs); this is not an acoustic measurement")
            let start = ProcessInfo.processInfo.systemUptime
            var sample = 0
            while ProcessInfo.processInfo.systemUptime-start < duration {
                var pcm = Data(capacity: 352*4)
                for _ in 0..<352 {
                    let value = Int16(sin(Double(sample)*2*Double.pi*440/44100)*700); var little = value.littleEndian
                    for _ in 0..<2 { withUnsafeBytes(of: &little) { pcm.append(contentsOf: $0) } }; sample += 1
                }
                sender.writePCM(pcm); Thread.sleep(forTimeInterval: 352/44100.0)
            }
            Thread.sleep(forTimeInterval: 0.3)
            print("packetsSent=\(sender.packetsSent) droppedFrames=\(sender.droppedFrames) error=\(sender.lastError ?? "none")")
            if let e = sender.lastError { throw NakuAirPlayError.network(e) }
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }
}
