// NAKU AirPlay 2 realtime sender. Independent Swift implementation using the
// MIT-licensed pyatv protocol as an interoperability reference. No Unisson code.
// Transient pairing obeys HomePod's access policy; HTTP 403 is never bypassed.
import Foundation
import CoreFoundation
import CryptoKit
import Security
import Darwin

public enum NakuAirPlayError: Error, LocalizedError {
    case invalid(String), network(String), protocolError(String), denied
    public var errorDescription: String? {
        switch self {
        case .invalid(let s), .network(let s), .protocolError(let s): return s
        case .denied: return "HomePod 拒绝配对（403）。请检查家庭 App 的扬声器访问权限；NAKU 不会绕过访问限制。"
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T { lock(); defer { unlock() }; return try body() }
}
private extension Data {
    mutating func addBE<T: FixedWidthInteger>(_ value: T) { var v = value.bigEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
    mutating func addLE<T: FixedWidthInteger>(_ value: T) { var v = value.littleEndian; Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) } }
    func be16(_ p: Int) -> UInt16 { UInt16(self[startIndex+p]) << 8 | UInt16(self[startIndex+p+1]) }
    func le16(_ p: Int) -> UInt16 { UInt16(self[startIndex+p]) | UInt16(self[startIndex+p+1]) << 8 }
}
private func randomData(_ count: Int) throws -> Data {
    var data = Data(count: count)
    let result = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
    guard result == errSecSuccess else { throw NakuAirPlayError.invalid("Secure random generation failed") }
    return data
}
private func digest(_ parts: Data...) -> Data { var h = SHA512(); parts.forEach { h.update(data: $0) }; return Data(h.finalize()) }
private func derive(_ secret: Data, _ salt: String, _ info: String) -> SymmetricKey {
    HKDF<SHA512>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret), salt: Data(salt.utf8), info: Data(info.utf8), outputByteCount: 32)
}
private func bytes(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }
private func nonce(_ counter: UInt64) throws -> ChaChaPoly.Nonce { var d = Data(repeating: 0, count: 4); d.addLE(counter); return try ChaChaPoly.Nonce(data: d) }
private func seal(_ plain: Data, key: SymmetricKey, counter: UInt64, aad: Data = Data()) throws -> Data {
    let b = try ChaChaPoly.seal(plain, using: key, nonce: nonce(counter), authenticating: aad)
    return b.ciphertext + b.tag
}
private func unseal(_ wire: Data, key: SymmetricKey, counter: UInt64, aad: Data = Data()) throws -> Data {
    guard wire.count >= 16 else { throw NakuAirPlayError.protocolError("Truncated authenticated data") }
    let b = try ChaChaPoly.SealedBox(nonce: nonce(counter), ciphertext: wire.dropLast(16), tag: wire.suffix(16))
    return try ChaChaPoly.open(b, using: key, authenticating: aad)
}
private func tlv(_ pairs: [(UInt8, Data)]) -> Data {
    var out = Data()
    for (tag, data) in pairs {
        if data.isEmpty { out.append(contentsOf: [tag, 0]); continue }
        var offset = 0
        while offset < data.count { let n = min(255, data.count-offset); out.append(contentsOf: [tag, UInt8(n)]); out.append(data.subdata(in: offset..<offset+n)); offset += n }
    }
    return out
}
private func parseTLV(_ data: Data) throws -> [UInt8: Data] {
    var result: [UInt8: Data] = [:]; var p = 0
    while p < data.count {
        guard p+2 <= data.count else { throw NakuAirPlayError.protocolError("Truncated TLV header") }
        let tag = data[p], n = Int(data[p+1]); p += 2
        guard p+n <= data.count else { throw NakuAirPlayError.protocolError("Truncated TLV value") }
        result[tag, default: Data()].append(data.subdata(in: p..<p+n)); p += n
    }
    if let error = result[7]?.first { throw NakuAirPlayError.protocolError("HomePod pairing error \(error)") }
    return result
}

// HAP SRP-6a group3072 / SHA512. The RFC5054 prime is public protocol data.
private struct SRPProof {
    let publicKey: Data, proof: Data, expected: Data, sharedKey: Data
    static let primeHex = """
    FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA6
    3B139B22514A08798E3404DDEF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245
    E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F2411
    7C4B1FE649286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD24CF5F
    83655D23DCA3AD961C62F356208552BB9ED529077096966D670C354E4ABC9804F1746C08
    CA18217C32905E462E36CE3BE39E772C180E86039B2783A2EC07A28FB5C55DF06F4C52C9
    DE2BCBF6955817183995497CEA956AE515D2261898FA051015728E5A8AAAC42DAD33170D
    04507A33A85521ABDF1CBA64ECFB850458DBEF0A8AEA71575D060C7DB3970F85A6E1E4C7
    ABF5AE8CDB0933D71E8C94E04A25619DCEE3D2261AD2EE6BF12FFA06D98A0864D8760273
    3EC86A64521F2B18177B200CBBE117577A615D6C770988C0BAD946E208E24FA074E5AB31
    43DB5BFCE0FD108E4B82D120A93AD2CAFFFFFFFFFFFFFFFF
    """.filter { !$0.isWhitespace }
    static func make(salt: Data, server: Data, privateKey: Data) throws -> SRPProof {
        guard !salt.isEmpty, salt.count <= 64, !server.isEmpty, server.count <= 384 else { throw NakuAirPlayError.protocolError("Invalid SRP parameters") }
        let n = BigUInt(primeHex, radix: 16)!, g = BigUInt(5), a = BigUInt(privateKey), b = BigUInt(server)
        guard b % n != 0, a != 0 else { throw NakuAirPlayError.protocolError("Invalid SRP public value") }
        func pad(_ v: BigUInt) -> Data { let b = v.serialize(); return Data(repeating: 0, count: 384-b.count) + b }
        let A = g.power(a, modulus: n), publicKey = A.serialize()
        let k = BigUInt(digest(n.serialize(), pad(g)))
        let x = BigUInt(digest(salt, digest(Data("Pair-Setup:3939".utf8))))
        let u = BigUInt(digest(pad(A), pad(b)))
        guard u != 0 else { throw NakuAirPlayError.protocolError("Invalid SRP scrambling parameter") }
        let kgx = (k * g.power(x, modulus: n)) % n
        let base = (b + n - kgx) % n
        let shared = base.power(a + u*x, modulus: n)
        let key = digest(shared.serialize())
        let hN = digest(n.serialize()), hg = digest(g.serialize())
        let xor = Data(zip(hN, hg).map { $0 ^ $1 })
        let proof = digest(xor, digest(Data("Pair-Setup".utf8)), salt, publicKey, server, key)
        return SRPProof(publicKey: publicKey, proof: proof, expected: digest(publicKey, proof, key), sharedKey: key)
    }
}

private final class HAPFramer {
    let outKey: SymmetricKey, inKey: SymmetricKey
    var outCounter: UInt64 = 0, inCounter: UInt64 = 0
    var incoming = Data()
    init(outKey: SymmetricKey, inKey: SymmetricKey) { self.outKey = outKey; self.inKey = inKey }
    func encode(_ data: Data) throws -> Data {
        var wire = Data(); var p = 0
        while p < data.count {
            let n = min(1024, data.count-p); var size = Data(); size.addLE(UInt16(n))
            wire.append(size); wire.append(try seal(data.subdata(in: p..<p+n), key: outKey, counter: outCounter, aad: size)); outCounter &+= 1; p += n
        }
        return wire
    }
    func decode(_ data: Data) throws -> Data {
        incoming.append(data); var plain = Data()
        while incoming.count >= 2 {
            let n = Int(incoming.le16(0))
            guard n <= 1024 else { throw NakuAirPlayError.protocolError("Oversized encrypted control frame") }
            let full = 2+n+16; if incoming.count < full { break }
            let chunk = try unseal(incoming.subdata(in: 2..<full), key: inKey, counter: inCounter, aad: incoming.prefix(2))
            inCounter &+= 1; plain.append(chunk); incoming = Data(incoming.dropFirst(full))
        }
        guard incoming.count <= 1042 else { throw NakuAirPlayError.protocolError("Control frame buffer exceeded limit") }
        return plain
    }
}
private struct WireMessage {
    let firstLine: String, headers: [String: String], body: Data
    var code: Int { Int(firstLine.split(separator: " ").dropFirst().first ?? "0") ?? 0 }
    static func parse(_ data: inout Data) throws -> WireMessage? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > 65536 { throw NakuAirPlayError.protocolError("Oversized RTSP headers") }; return nil
        }
        let lines = String(decoding: data[..<range.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        var headers: [String: String] = [:]
        for line in lines.dropFirst() { if let p = line.firstIndex(of: ":") { headers[String(line[..<p]).lowercased()] = line[line.index(after: p)...].trimmingCharacters(in: .whitespaces) } }
        let n: Int
        if let value = headers["content-length"] { guard let size = Int(value), size >= 0, size <= 4*1024*1024 else { throw NakuAirPlayError.protocolError("Invalid RTSP content length") }; n = size } else { n = 0 }
        let start = range.upperBound
        guard data.count >= start+n else { return nil }
        let result = WireMessage(firstLine: lines.first ?? "", headers: headers, body: data.subdata(in: start..<start+n))
        data = Data(data.dropFirst(start+n)); return result
    }
}
private func socketError(_ action: String) -> NakuAirPlayError { .network("\(action): \(String(cString: strerror(errno)))") }
private func address4(_ address: String, _ port: UInt16) throws -> sockaddr_in {
    var a = sockaddr_in(); a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); a.sin_family = sa_family_t(AF_INET); a.sin_port = port.bigEndian
    guard address.withCString({ inet_pton(AF_INET, $0, &a.sin_addr) }) == 1 else { throw NakuAirPlayError.invalid("A numeric IPv4 HomePod address is required") }
    return a
}
private func connectTCP(_ host: String, _ port: UInt16) throws -> Int32 {
    let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw socketError("TCP socket") }
    do {
        var noSigPipe: Int32 = 1; _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var addr = try address4(host, port)
        let old = fcntl(fd, F_GETFL, 0); _ = fcntl(fd, F_SETFL, old | O_NONBLOCK)
        let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        if result < 0 {
            guard errno == EINPROGRESS else { throw socketError("TCP connect") }
            var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&p, 1, 4000) > 0 else { throw NakuAirPlayError.network("HomePod connection timed out") }
            var error: Int32 = 0; var length = socklen_t(MemoryLayout<Int32>.size); _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length)
            guard error == 0 else { throw NakuAirPlayError.network("HomePod connection failed: \(String(cString: strerror(error)))") }
        }
        _ = fcntl(fd, F_SETFL, old)
        var timeout = timeval(tv_sec: 4, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)); _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var nodelay: Int32 = 1; _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &nodelay, socklen_t(MemoryLayout<Int32>.size))
        return fd
    } catch { Darwin.close(fd); throw error }
}
private final class RTSPConnection {
    private enum ReadError: Error { case idleTimeout }
    enum ResponseSequence { case matched, stale }
    private var fd: Int32
    private let lock = NSLock()
    private let shutdownLock = NSLock()
    private var framer: HAPFramer?
    private var received = Data()
    private var cseq = 0
    private let channel: String
    private let diagnostic: ((String) -> Void)?
    let localIP: String
    let clientID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16)
    var session: String?
    init(_ host: String, _ port: UInt16, channel: String = "control", diagnostic: ((String) -> Void)? = nil) throws {
        self.channel = channel; self.diagnostic = diagnostic
        let descriptor = try connectTCP(host, port); fd = descriptor
        var a = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &a) { _ = $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) } }
        var b = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN)); _ = inet_ntop(AF_INET, &a.sin_addr, &b, socklen_t(b.count)); localIP = String(cString: b)
    }
    private init(fixtureDescriptor: Int32) {
        fd = fixtureDescriptor; channel = "fixture"; diagnostic = nil; localIP = "127.0.0.1"
        var noSigPipe: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
    }
    static func selfTestClosedTransport(key: SymmetricKey) throws {
        // A local UNIX socket pair exercises EOF and invalidation without opening
        // a network connection or touching an audio device.
        func eofFixture() throws -> (connection: RTSPConnection, peer: Int32) {
            var descriptors = [Int32](repeating: -1, count: 2)
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else { throw socketError("Fixture socket pair") }
            // Leave the peer's read half open so the request is accepted; its
            // closed write half then produces deterministic EOF on our receive.
            _ = shutdown(descriptors[1], SHUT_WR)
            return (RTSPConnection(fixtureDescriptor: descriptors[0]), descriptors[1])
        }
        let controlFixture = try eofFixture(), control = controlFixture.connection
        defer { control.close(); Darwin.close(controlFixture.peer) }
        control.enable(out: key, input: key)
        var rejected = false
        do { _ = try control.request("POST", "/feedback") } catch { rejected = true }
        guard rejected, control.fd == -1 else { throw NakuAirPlayError.invalid("Self-test: failed control transport stayed usable") }
        let nonceAfterFailure = control.framer?.outCounter
        do { _ = try control.request("POST", "/feedback") } catch { }
        guard nonceAfterFailure == control.framer?.outCounter else { throw NakuAirPlayError.invalid("Self-test: invalidated transport encoded another HAP record") }
        let eventFixture = try eofFixture(), event = eventFixture.connection
        defer { event.close(); Darwin.close(eventFixture.peer) }
        var failures = 0
        event.eventLoop(whileRunning: { true }, onFailure: { _ in failures += 1 })
        guard failures == 1, event.fd == -1 else { throw NakuAirPlayError.invalid("Self-test: event EOF did not terminate once") }
    }
    func enable(out: SymmetricKey, input: SymmetricKey) { lock.withLock { framer = HAPFramer(outKey: out, inKey: input) } }
    func close() {
        // Wake a blocked receive before waiting for the operation lock. The actual
        // close stays serialized so a reused descriptor cannot be read or written.
        shutdownLock.withLock { if fd >= 0 { _ = shutdown(fd, SHUT_RDWR) } }
        lock.withLock { invalidateLocked() }
    }
    private func invalidateLocked() {
        shutdownLock.withLock { if fd >= 0 { _ = shutdown(fd, SHUT_RDWR); Darwin.close(fd); fd = -1 } }
    }
    private func send(_ plain: Data) throws {
        let wire = try framer?.encode(plain) ?? plain
        try wire.withUnsafeBytes { b in
            var offset = 0
            while offset < b.count {
                let n = Darwin.send(fd, b.baseAddress!.advanced(by: offset), b.count-offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else {
                    if n == 0 { throw NakuAirPlayError.network("HomePod closed connection during send") }
                    throw socketError("RTSP send")
                }
                offset += n
            }
        }
    }
    private func receive(until deadline: TimeInterval? = nil) throws -> WireMessage {
        while true {
            if let message = try WireMessage.parse(&received) { return message }
            let remaining = deadline.map { $0-ProcessInfo.processInfo.systemUptime } ?? 4
            guard remaining > 0 else { throw ReadError.idleTimeout }
            var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, Int32(max(1, ceil(min(remaining, 4)*1000))))
            if ready < 0 && errno == EINTR { continue }
            if ready == 0 { throw ReadError.idleTimeout }
            guard ready > 0 else { throw socketError("RTSP poll") }
            var buffer = [UInt8](repeating: 0, count: 16384)
            let n = Darwin.recv(fd, &buffer, buffer.count, 0)
            if n < 0 && errno == EINTR { continue }
            if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { throw ReadError.idleTimeout }
            if n == 0 { throw NakuAirPlayError.network("HomePod closed connection (EOF)") }
            guard n > 0 else { throw socketError("RTSP receive") }
            let data = Data(buffer.prefix(n))
            if let framer {
                do { received.append(try framer.decode(data)) }
                catch { throw NakuAirPlayError.protocolError("Encrypted control frame rejected: \(error.localizedDescription)") }
            } else { received.append(data) }
        }
    }
    static func responseSequence(_ reply: WireMessage, expected: Int, requiresSequence: Bool) throws -> ResponseSequence {
        let parts = reply.firstLine.split(separator: " ")
        guard parts.count >= 2, ["RTSP/1.0", "HTTP/1.0", "HTTP/1.1"].contains(String(parts[0])),
              (100...599).contains(reply.code) else { throw NakuAirPlayError.protocolError("Invalid control response line") }
        guard let value = reply.headers["cseq"] else {
            // The HTTP pairing endpoints do not require CSeq. RTSP does.
            guard !requiresSequence && !parts[0].hasPrefix("RTSP/") else { throw NakuAirPlayError.protocolError("Control response is missing CSeq") }
            return .matched
        }
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let sequence = Int(value) else {
            throw NakuAirPlayError.protocolError("Control response has invalid CSeq")
        }
        guard sequence <= expected else { throw NakuAirPlayError.protocolError("Control response has future CSeq \(sequence), expected \(expected)") }
        return sequence == expected ? .matched : .stale
    }
    static func eventResponse(_ request: WireMessage) throws -> (wire: Data, method: String, protocolToken: String, sequence: String?) {
        let parts = request.firstLine.split(separator: " ")
        guard parts.count == 3, !parts[0].isEmpty, parts[0].count <= 32,
              parts[0].utf8.allSatisfy({ (65...90).contains($0) || $0 == 95 || $0 == 45 }),
              ["RTSP/1.0", "HTTP/1.0", "HTTP/1.1"].contains(String(parts[2])) else {
            throw NakuAirPlayError.protocolError("Invalid event request line")
        }
        let protocolToken = String(parts[2]), sequence = request.headers["cseq"]
        if let sequence {
            guard !sequence.isEmpty, sequence.count <= 32, sequence.utf8.allSatisfy({ (48...57).contains($0) }) else {
                throw NakuAirPlayError.protocolError("Event request has invalid CSeq")
            }
        }
        var h = "\(protocolToken) 200 OK\r\nContent-Length: 0\r\nAudio-Latency: 0\r\n"
        if let sequence { h += "CSeq: \(sequence)\r\n" }
        if let server = request.headers["server"] { h += "Server: \(server)\r\n" }
        return (Data((h+"\r\n").utf8), String(parts[0]), protocolToken, sequence)
    }
    func request(_ method: String, _ path: String, body: Data = Data(), headers: [String: String] = [:], http: Bool = false) throws -> WireMessage {
        try lock.withLock {
            guard fd >= 0 else { throw NakuAirPlayError.network("Connection is closed") }
            cseq += 1
            let operation = method + " " + (["/info", "/feedback", "/pair-pin-start", "/pair-setup"].contains(path) ? path : "session")
            let started = ProcessInfo.processInfo.systemUptime
            var h = ["CSeq": String(cseq), "User-Agent": "AirPlay/550.10", "DACP-ID": String(clientID), "Active-Remote": "1", "Client-Instance": String(clientID), "Content-Length": String(body.count)]
            if let session { h["Session"] = session }
            headers.forEach { h[$0.key] = $0.value }
            let head = "\(method) \(path) \(http ? "HTTP/1.1" : "RTSP/1.0")\r\n" + h.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)\r\n" }.joined() + "\r\n"
            diagnostic?("\(channel) request \(operation) cseq=\(cseq)")
            do {
                try send(Data(head.utf8) + body)
                var staleCount = 0
                while true {
                    let reply = try receive(until: started+4)
                    if try Self.responseSequence(reply, expected: cseq, requiresSequence: !http) == .stale {
                        staleCount += 1
                        diagnostic?("\(channel) stale response cseq=\(reply.headers["cseq"] ?? "missing") expected=\(cseq)")
                        guard staleCount <= 8 else { throw NakuAirPlayError.protocolError("Too many stale control responses") }
                        continue
                    }
                    let elapsedMs = (ProcessInfo.processInfo.systemUptime-started)*1000
                    diagnostic?("\(channel) reply \(operation) cseq=\(cseq) status=\(reply.code) rttMs=\(Int(elapsedMs.rounded()))")
                    if reply.code == 403 { throw NakuAirPlayError.denied }
                    guard (200..<300).contains(reply.code) else { throw NakuAirPlayError.protocolError("\(operation) returned \(reply.code)") }
                    if let session = reply.headers["session"] { self.session = session.components(separatedBy: ";").first }
                    return reply
                }
            } catch {
                // HAP record nonces advance when encoding. After a partial write or
                // timed-out exchange, never send a fresh request on this transport.
                invalidateLocked()
                let reason = error is ReadError ? "Control response timed out" : error.localizedDescription
                diagnostic?("\(channel) error \(operation) cseq=\(cseq): \(reason)")
                if case NakuAirPlayError.denied = error { throw NakuAirPlayError.denied }
                throw NakuAirPlayError.network("\(operation) CSeq \(cseq): \(reason)")
            }
        }
    }
    func eventLoop(whileRunning: () -> Bool, onFailure: (Error) -> Void) {
        while whileRunning() {
            do {
                try lock.withLock {
                    guard fd >= 0 else { throw NakuAirPlayError.network("Event connection is closed") }
                    let reply = try Self.eventResponse(receive())
                    diagnostic?("events request method=\(reply.method) protocol=\(reply.protocolToken) cseq=\(reply.sequence ?? "missing")")
                    try send(reply.wire)
                    diagnostic?("events reply status=200 cseq=\(reply.sequence ?? "missing")")
                }
            } catch {
                if !whileRunning() { return }
                let idle = error is ReadError && lock.withLock { received.isEmpty && (framer?.incoming.isEmpty ?? true) }
                if idle { continue }
                lock.withLock { invalidateLocked() }
                let reason = error is ReadError ? "Incomplete event message timed out" : error.localizedDescription
                let failure = NakuAirPlayError.network("HomePod event channel: \(reason)")
                diagnostic?("events terminal error: \(reason)")
                onFailure(failure)
                return
            }
        }
    }
}

public final class NakuAirPlaySender {
    /// Protocol stages and counters only; never includes bodies, keys or media URLs.
    public var onDiagnostic: ((String) -> Void)?
    public let configuredLatencyMs: Int
    public var packetsSent: UInt64 { state.withLock { packetCount } }
    public var droppedFrames: UInt64 { state.withLock { droppedCount } }
    public var lastError: String? { state.withLock { errorText } }
    public var isConnected: Bool { state.withLock { running } }
    public var initialReceiverVolume: Double? { state.withLock { reportedInitialVolume } }
    private let address: String, port: UInt16
    private let state = NSLock(), lifecycle = NSLock()
    private var networkActive = false
    private var running = false, packetCount: UInt64 = 0, droppedCount: UInt64 = 0, errorText: String?
    private var reportedInitialVolume: Double?
    private var pendingPCM = Data()
    private var connection: RTSPConnection?, events: RTSPConnection?
    private var audioFD: Int32 = -1, controlFD: Int32 = -1, timingFD: Int32 = -1
    private var audioDest = sockaddr_in(), controlDest = sockaddr_in()
    private var audioKey = SymmetricKey(size: .bits256)
    private var seq = UInt16.random(in: .min ... .max), rtp = UInt32.random(in: .min ... .max), ssrc = UInt32.random(in: 1 ... .max), counter: UInt64 = 0
    private var history: [UInt16: Data] = [:], historyOrder: [UInt16] = []
    private let workerGroup = DispatchGroup()
    private var startWall = Date().timeIntervalSince1970, framesSent: UInt64 = 0, firstSync = true
    private var uri = ""
    private static let frames = 352, pcmBytes = 1408, maximumPCMBytes = 1408*12
    public init(address: String, port: UInt16 = 7000, latencyMs: Int = 120) { self.address = address; self.port = port; configuredLatencyMs = max(20, min(latencyMs, 2000)) }

    public func connect() throws {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard !isConnected else { return }
        var phase = "initial TCP"
        { didSet { onDiagnostic?(phase) } }
        onDiagnostic?(phase)
        do {
            if connection != nil { state.withLock { running = false; networkActive = false }; events?.close(); _ = workerGroup.wait(timeout: .now()+5); cleanup() }
            state.withLock { errorText = nil; reportedInitialVolume = nil; packetCount = 0; droppedCount = 0; pendingPCM.removeAll(keepingCapacity: true) }
            let conn = try RTSPConnection(address, port, diagnostic: { [weak self] in self?.onDiagnostic?($0) }); connection = conn
            uri = "rtsp://\(conn.localIP)/\(ssrc)"
            phase = "GET info"
            let info = try conn.request("GET", "/info")
            if let properties = (try? PropertyListSerialization.propertyList(from: info.body, options: [], format: nil)) as? [String: Any] {
                state.withLock { reportedInitialVolume = Self.normalizedReceiverVolume(properties["initialVolume"]) }
            }
            let h = ["X-Apple-HKP": "4", "Content-Type": "application/octet-stream", "Connection": "keep-alive"]
            phase = "pair-pin-start"
            _ = try conn.request("POST", "/pair-pin-start", headers: h, http: true)
            phase = "SRP M1/M2"
            let m2 = try conn.request("POST", "/pair-setup", body: tlv([(0, Data([0])), (6, Data([1])), (0x13, Data([0x10]))]), headers: h, http: true)
            let t2 = try parseTLV(m2.body)
            guard t2[6] == Data([2]), let salt = t2[2], let publicKey = t2[3] else { throw NakuAirPlayError.protocolError("Invalid pairing M2") }
            phase = "SRP compute"
            let proof = try SRPProof.make(salt: salt, server: publicKey, privateKey: randomData(32))
            phase = "SRP M3/M4"
            let m4 = try conn.request("POST", "/pair-setup", body: tlv([(6, Data([3])), (3, proof.publicKey), (4, proof.proof)]), headers: h, http: true)
            let t4 = try parseTLV(m4.body)
            guard t4[6] == Data([4]), let serverProof = t4[4], Self.equal(serverProof, proof.expected) else { throw NakuAirPlayError.protocolError("HomePod SRP server proof mismatch") }
            conn.enable(out: derive(proof.sharedKey, "Control-Salt", "Control-Write-Encryption-Key"), input: derive(proof.sharedKey, "Control-Salt", "Control-Read-Encryption-Key"))
            timingFD = try udpSocket(local: conn.localIP); controlFD = try udpSocket(local: conn.localIP); audioFD = try udpSocket(local: conn.localIP)
            audioDest = try address4(address, 0)
            state.withLock { networkActive = true }
            startTimingWorker()
            let base: [String: Any] = ["deviceID": "02:4E:41:4B:55:01", "sessionUUID": UUID().uuidString, "timingPort": Int(try localPort(timingFD)), "timingProtocol": "NTP", "isMultiSelectAirPlay": true, "groupContainsGroupLeader": false, "macAddress": "02:4E:41:4B:55:01", "model": "Mac", "name": "NAKU", "osName": "macOS", "osVersion": ProcessInfo.processInfo.operatingSystemVersionString, "senderSupportsRelay": false, "sourceVersion": "690.7.1", "statsCollectionEnabled": false]
            phase = "encrypted session SETUP"
            let response = try plistRequest("SETUP", base)
            if let eventPort = (response["eventPort"] as? NSNumber)?.uint16Value, eventPort != 0 {
                phase = "event channel"
                var eventConn: RTSPConnection?
                for attempt in 0..<5 { do { eventConn = try RTSPConnection(address, eventPort, channel: "events", diagnostic: { [weak self] in self?.onDiagnostic?($0) }); break } catch { if attempt == 4 { throw error }; Thread.sleep(forTimeInterval: 0.15) } }
                if let eventConn {
                    // The event channel's key direction is opposite the control channel.
                    eventConn.enable(out: derive(proof.sharedKey, "Events-Salt", "Events-Read-Encryption-Key"), input: derive(proof.sharedKey, "Events-Salt", "Events-Write-Encryption-Key")); events = eventConn
                }
            }
            audioKey = derive(proof.sharedKey, "Events-Salt", "Events-Write-Encryption-Key")
            let latency = configuredLatencyMs*44100/1000
            let streams: [[String: Any]] = [["audioFormat": 0x800, "audioMode": "default", "controlPort": Int(try localPort(controlFD)), "ct": 1, "isMedia": true, "latencyMin": latency, "latencyMax": latency, "shk": bytes(audioKey), "spf": Self.frames, "sr": 44100, "type": 96, "supportsDynamicStreamID": false, "streamConnectionID": Int64(ssrc)]]
            phase = "encrypted audio SETUP"
            let streamReply = try plistRequest("SETUP", ["streams": streams])
            guard let stream = (streamReply["streams"] as? [[String: Any]])?.first, let dataPort = (stream["dataPort"] as? NSNumber)?.uint16Value, dataPort != 0, let remoteControl = (stream["controlPort"] as? NSNumber)?.uint16Value, remoteControl != 0 else { throw NakuAirPlayError.protocolError("HomePod did not provide audio/control ports") }
            audioDest = try address4(address, dataPort); controlDest = try address4(address, remoteControl)
            seq = UInt16.random(in: .min ... .max); rtp = UInt32.random(in: .min ... .max); counter = 0; framesSent = 0; firstSync = true
            phase = "RECORD"
            _ = try conn.request("RECORD", uri, headers: ["Range": "npt=0-", "RTP-Info": "seq=\(seq);rtptime=\(rtp)"])
            phase = "initial FLUSH"
            _ = try conn.request("FLUSH", uri, headers: ["Range": "npt=0-", "RTP-Info": "seq=\(seq);rtptime=\(rtp)"])
            startWall = Date().timeIntervalSince1970
            state.withLock { running = true }
            startWorkers()
        } catch {
            let contextual = NakuAirPlayError.network("HomePod connect [\(phase)]: \(error.localizedDescription)")
            state.withLock { errorText = contextual.localizedDescription; running = false; networkActive = false }
            _ = workerGroup.wait(timeout: .now()+5)
            cleanup(); throw contextual
        }
    }

    public func writePCM(_ data: Data) {
        guard !data.isEmpty else { return }
        state.withLock {
            guard running else { return }
            let valid = data.count - data.count % 4
            guard valid > 0 else { return }
            if valid >= Self.maximumPCMBytes {
                droppedCount += UInt64((pendingPCM.count+valid-Self.maximumPCMBytes)/4)
                pendingPCM = data.subdata(in: valid-Self.maximumPCMBytes..<valid)
                return
            }
            let incoming = data.prefix(valid)
            pendingPCM.append(incoming)
            if pendingPCM.count > Self.maximumPCMBytes {
                let drop = ((pendingPCM.count-Self.maximumPCMBytes+3)/4)*4
                pendingPCM = Data(pendingPCM.dropFirst(drop)); droppedCount += UInt64(drop/4)
            }
        }
    }
    public func setVolume(_ normalized: Double) {
        guard normalized.isFinite, isConnected else { return }
        do { try setReceiverVolume(max(0, min(normalized, 1))) }
        catch { state.withLock { errorText = error.localizedDescription } }
    }
    public func setReceiverVolume(_ normalized: Double) throws {
        let db = try Self.receiverVolumeDBFS(normalized)
        guard let conn = connection, isConnected else { throw NakuAirPlayError.network("HomePod is not connected") }
        do { _ = try conn.request("SET_PARAMETER", uri, body: Data("volume: \(db)\r\n".utf8), headers: ["Content-Type": "text/parameters"]) }
        catch { fail(error); throw error }
    }
    private static func normalizedReceiverVolume(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let db = number.doubleValue
        guard db.isFinite, (-144...0).contains(db) else { return nil }
        return max(0, (db+30)/30)
    }
    private static func receiverVolumeDBFS(_ normalized: Double) throws -> Double {
        guard normalized.isFinite, (0...1).contains(normalized) else { throw NakuAirPlayError.invalid("HomePod volume must be finite and between 0 and 1") }
        return normalized == 0 ? -144 : -30+normalized*30
    }
    public func flush() throws {
        guard let conn = connection, isConnected else { return }
        // Keep the continuously paced RTP timeline; only discard queued pre-seek samples.
        state.withLock { pendingPCM.removeAll(keepingCapacity: true) }
        _ = try conn.request("FLUSH", uri)
    }
    public func close() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        state.withLock { running = false; networkActive = false; pendingPCM.removeAll() }
        events?.close()
        _ = workerGroup.wait(timeout: .now()+5)
        if let conn = connection { _ = try? conn.request("TEARDOWN", uri) }
        cleanup()
    }
    deinit { close() }
    private func cleanup() {
        events?.close(); events = nil; connection?.close(); connection = nil
        for fd in [audioFD, controlFD, timingFD] where fd >= 0 { _ = shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
        audioFD = -1; controlFD = -1; timingFD = -1; history.removeAll(); historyOrder.removeAll()
    }
    private func plistRequest(_ method: String, _ value: [String: Any]) throws -> [String: Any] {
        guard let conn = connection else { throw NakuAirPlayError.network("Not connected") }
        let body = try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
        let reply = try conn.request(method, uri, body: body, headers: ["Content-Type": "application/x-apple-binary-plist"])
        guard let result = try PropertyListSerialization.propertyList(from: reply.body, options: [], format: nil) as? [String: Any] else { throw NakuAirPlayError.protocolError("Invalid HomePod setup plist") }; return result
    }
    private func udpSocket(local: String) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0); guard fd >= 0 else { throw socketError("UDP socket") }
        do {
            var a = try address4(local, 0)
            let r = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard r == 0 else { throw socketError("UDP bind") }
            let flags = fcntl(fd, F_GETFL, 0); _ = fcntl(fd, F_SETFL, flags|O_NONBLOCK); return fd
        } catch { Darwin.close(fd); throw error }
    }
    private func localPort(_ fd: Int32) throws -> UInt16 {
        var a = sockaddr_in(); var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let r = withUnsafeMutablePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard r == 0 else { throw socketError("UDP getsockname") }; return UInt16(bigEndian: a.sin_port)
    }
    private func startTimingWorker() {
        let expectedPeer = audioDest.sin_addr.s_addr
        workerGroup.enter()
        DispatchQueue(label: "naku.airplay.ntp", qos: .userInteractive).async { [weak self] in
            defer { self?.workerGroup.leave() }
            var requests: UInt64 = 0, replies: UInt64 = 0, failures: UInt64 = 0
            var nextDiagnostic = ProcessInfo.processInfo.systemUptime+10
            while let self, self.state.withLock({ self.networkActive }) {
                for _ in 0..<16 {
                    var buffer = [UInt8](repeating: 0, count: 2048), peer = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
                    let n = withUnsafeMutablePointer(to: &peer) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(self.timingFD, &buffer, buffer.count, 0, $0, &length) } }
                    guard n > 0 else { break }
                    guard n >= 32, buffer[1]&0x7f == 0x52, peer.sin_addr.s_addr == expectedPeer else { continue }
                    requests &+= 1
                    let now = Self.ntp(Date().timeIntervalSince1970)
                    var reply = Data([buffer[0], 0xD3]); reply.addBE(UInt16(7)); reply.addBE(UInt32(0)); reply.append(Data(buffer[24..<32])); reply.addBE(now); reply.addBE(Self.ntp(Date().timeIntervalSince1970))
                    do { try self.sendUDP(reply, fd: self.timingFD, destination: peer); replies &+= 1 }
                    catch { failures &+= 1; if failures == 1 || failures%32 == 0 { self.onDiagnostic?("ntp reply error count=\(failures): \(error.localizedDescription)") } }
                }
                let now = ProcessInfo.processInfo.systemUptime
                if now >= nextDiagnostic {
                    self.onDiagnostic?("ntp requests=\(requests) replies=\(replies) failures=\(failures)")
                    nextDiagnostic = now+10
                }
                Thread.sleep(forTimeInterval: 0.002)
            }
        }
    }
    private func startWorkers() {
        workerGroup.enter()
        DispatchQueue(label: "naku.airplay.audio", qos: .userInteractive).async { [weak self] in
            defer { self?.workerGroup.leave() }; self?.audioLoop()
        }
        if let events {
            workerGroup.enter()
            DispatchQueue(label: "naku.airplay.events", qos: .utility).async { [weak self] in
                defer { self?.workerGroup.leave() }
                events.eventLoop(whileRunning: { self?.isConnected ?? false }, onFailure: { self?.fail($0) })
            }
        }
        workerGroup.enter()
        DispatchQueue(label: "naku.airplay.feedback", qos: .utility).async { [weak self] in
            defer { self?.workerGroup.leave() }
            while let self, self.isConnected {
                for _ in 0..<20 { if !self.isConnected { return }; Thread.sleep(forTimeInterval: 0.1) }
                guard self.isConnected else { return }
                do {
                    guard let connection = self.connection else { throw NakuAirPlayError.network("HomePod control connection is unavailable") }
                    _ = try connection.request("POST", "/feedback")
                } catch { if self.isConnected { self.fail(error) }; return }
            }
        }
    }
    private func fail(_ error: Error) {
        let firstFailure = state.withLock { () -> Bool in
            guard running || networkActive else { return false }
            errorText = error.localizedDescription; running = false; networkActive = false
            return true
        }
        if firstFailure { onDiagnostic?("sender terminal error: \(error.localizedDescription)") }
    }
    private func audioLoop() {
        let period = Double(Self.frames)/44100.0
        var next = ProcessInfo.processInfo.systemUptime, nextSync = next
        while isConnected {
            let now = ProcessInfo.processInfo.systemUptime
            if now < next { Thread.sleep(forTimeInterval: min(next-now, 0.003)); continue }
            if now-next > period*3 { next = now }
            do {
                serviceDatagrams()
                if now >= nextSync { try syncPacket(); nextSync = now+1 }
                let pcm: Data = state.withLock {
                    let n = min(Self.pcmBytes, pendingPCM.count); var d = Data(pendingPCM.prefix(n)); pendingPCM = Data(pendingPCM.dropFirst(n)); if n < Self.pcmBytes { d.append(Data(repeating: 0, count: Self.pcmBytes-n)) }; return d
                }
                let packet = try audioPacket(pcm)
                try sendUDP(packet, fd: audioFD, destination: audioDest)
                history[seq] = packet; historyOrder.append(seq)
                if historyOrder.count > 256 { history.removeValue(forKey: historyOrder.removeFirst()) }
                seq &+= 1; rtp &+= UInt32(Self.frames); framesSent += UInt64(Self.frames)
                state.withLock { packetCount &+= 1 }
            } catch { fail(error); break }
            next += period
        }
    }
    private func audioPacket(_ littlePCM: Data) throws -> Data {
        guard littlePCM.count == Self.pcmBytes else { throw NakuAirPlayError.invalid("PCM packet must contain352 stereo frames") }
        var header = Data([0x80, counter == 0 ? 0xE0 : 0x60]); header.addBE(seq); header.addBE(rtp); header.addBE(ssrc)
        var networkPCM = Data(count: Self.pcmBytes)
        networkPCM.withUnsafeMutableBytes { dst in littlePCM.withUnsafeBytes { src in let a = src.bindMemory(to: UInt8.self), b = dst.bindMemory(to: UInt8.self); for i in stride(from: 0, to: Self.pcmBytes, by: 2) { b[i] = a[i+1]; b[i+1] = a[i] } } }
        var packet = header + (try seal(networkPCM, key: audioKey, counter: counter, aad: header.subdata(in: 4..<12)))
        packet.addLE(counter); counter &+= 1; return packet
    }
    private func syncPacket() throws {
        let time = Self.ntp(startWall+Double(framesSent)/44100.0)
        let latency = UInt32(configuredLatencyMs*44100/1000)
        var packet = Data([firstSync ? 0x90 : 0x80, 0xD4]); packet.addBE(UInt16(7)); packet.addBE(rtp &- latency); packet.addBE(UInt32(truncatingIfNeeded: time >> 32)); packet.addBE(UInt32(truncatingIfNeeded: time)); packet.addBE(rtp)
        try sendUDP(packet, fd: controlFD, destination: controlDest); firstSync = false
    }
    private func serviceDatagrams() {
        for fd in [controlFD] {
            for _ in 0..<16 {
                var buffer = [UInt8](repeating: 0, count: 2048), peer = sockaddr_in(), length = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &peer) { p in p.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(fd, &buffer, buffer.count, 0, $0, &length) } }
                guard n > 0 else { break }
                let data = Data(buffer.prefix(n)); guard data.count >= 4 else { continue }
                // Only respond to our selected receiver, not arbitrary LAN hosts.
                guard peer.sin_addr.s_addr == audioDest.sin_addr.s_addr else { continue }
                if fd == timingFD, data.count >= 32, data[1]&0x7f == 0x52 {
                    let now = Self.ntp(Date().timeIntervalSince1970)
                    var reply = Data([data[0], 0xD3]); reply.addBE(UInt16(7)); reply.addBE(UInt32(0)); reply.append(data.subdata(in: 24..<32)); reply.addBE(now); reply.addBE(Self.ntp(Date().timeIntervalSince1970)); try? sendUDP(reply, fd: fd, destination: peer)
                } else if fd == controlFD, data.count >= 8, data[1]&0x7f == 0x55 {
                    let first = data.be16(4), count = min(Int(data.be16(6)), 128)
                    for offset in 0..<count { let id = first &+ UInt16(offset); if let packet = history[id] { var reply = Data([0x80, 0xD6]); reply.addBE(id); reply.append(packet); try? sendUDP(reply, fd: fd, destination: peer) } }
                }
            }
        }
    }
    private func sendUDP(_ data: Data, fd: Int32, destination: sockaddr_in) throws {
        var a = destination
        let count = data.withUnsafeBytes { b in withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, b.baseAddress, b.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } } }
        guard count == data.count else { throw socketError("Audio UDP send") }
    }
    private static func ntp(_ unix: Double) -> UInt64 { let whole = floor(unix); return (UInt64(whole+2208988800)<<32) | UInt64((unix-whole)*4294967296) }
    private static func equal(_ a: Data, _ b: Data) -> Bool { guard a.count == b.count else { return false }; var diff: UInt8 = 0; for (x,y) in zip(a,b) { diff |= x^y }; return diff == 0 }

    public static func selfTest() throws {
        func require(_ ok: @autoclosure () throws -> Bool, _ message: String) throws { if try !ok() { throw NakuAirPlayError.invalid("Self-test: "+message) } }
        let long = Data((0..<800).map { UInt8($0%251) }); try require(try parseTLV(tlv([(3,long)]))[3] == long, "fragmented TLV roundtrip")
        do { _ = try parseTLV(Data([3,2,1])); throw NakuAirPlayError.invalid("Self-test accepted malformed TLV") } catch NakuAirPlayError.protocolError { }
        let key = SymmetricKey(data: Data(repeating: 7, count: 32)); let a = HAPFramer(outKey: key, inKey: key), b = HAPFramer(outKey: key, inKey: key)
        let source = Data((0..<4099).map { UInt8($0%253) }), encrypted = try a.encode(source)
        var decoded = Data(); for byte in encrypted { decoded.append(try b.decode(Data([byte]))) }; try require(decoded == source, "incremental framed crypto roundtrip")
        var messages = Data("RTSP/1.0 200 OK\r\nCSeq: 3\r\nContent-Length: 4\r\n\r\ntestHTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8)
        let first = try WireMessage.parse(&messages), second = try WireMessage.parse(&messages); try require(first?.body == Data("test".utf8) && second?.code == 200 && messages.isEmpty, "RTSP framing")
        for protocolToken in ["HTTP/1.1", "HTTP/1.0", "RTSP/1.0"] {
            var requestBytes = Data("POST /event \(protocolToken)\r\nCSeq: 27\r\nServer: AirTunes/fixture\r\nContent-Length: 0\r\n\r\n".utf8)
            guard let request = try WireMessage.parse(&requestBytes) else { throw NakuAirPlayError.invalid("Self-test: event request was incomplete") }
            let response = try RTSPConnection.eventResponse(request)
            var responseBytes = response.wire
            let parsed = try WireMessage.parse(&responseBytes)
            try require(parsed?.firstLine == "\(protocolToken) 200 OK" && parsed?.headers["cseq"] == "27" && parsed?.headers["server"] == "AirTunes/fixture" && parsed?.headers["audio-latency"] == "0" && responseBytes.isEmpty, "event protocol, CSeq and Server echo")
        }
        func response(_ sequence: String?, protocolToken: String = "RTSP/1.0") -> WireMessage {
            WireMessage(firstLine: "\(protocolToken) 200 OK", headers: sequence.map { ["cseq": $0] } ?? [:], body: Data())
        }
        func protocolRejects(_ body: () throws -> Void) -> Bool {
            do { try body(); return false } catch NakuAirPlayError.protocolError { return true } catch { return false }
        }
        try require(try RTSPConnection.responseSequence(response("7"), expected: 7, requiresSequence: true) == .matched, "matched control CSeq")
        try require(try RTSPConnection.responseSequence(response("6"), expected: 7, requiresSequence: true) == .stale, "stale control CSeq is distinguishable")
        try require(protocolRejects { _ = try RTSPConnection.responseSequence(response("8"), expected: 7, requiresSequence: true) }, "future control CSeq is rejected")
        try require(protocolRejects { _ = try RTSPConnection.responseSequence(response(nil), expected: 7, requiresSequence: true) }, "missing RTSP CSeq is rejected")
        try require(protocolRejects { _ = try RTSPConnection.responseSequence(response("invalid"), expected: 7, requiresSequence: true) }, "malformed control CSeq is rejected")
        try require(try RTSPConnection.responseSequence(response(nil, protocolToken: "HTTP/1.1"), expected: 7, requiresSequence: false) == .matched, "HTTP pairing may omit CSeq")
        try require(protocolRejects { _ = try RTSPConnection.responseSequence(response(nil, protocolToken: "HTTP/1.1"), expected: 7, requiresSequence: true) }, "HTTP-formatted RTSP response still requires CSeq")
        try RTSPConnection.selfTestClosedTransport(key: key)
        let infoBytes = try PropertyListSerialization.data(fromPropertyList: ["initialVolume": -15.0], format: .binary, options: 0)
        let info = try PropertyListSerialization.propertyList(from: infoBytes, options: [], format: nil) as! [String: Any]
        try require(Self.normalizedReceiverVolume(info["initialVolume"]) == 0.5, "initial receiver volume -15 dBFS maps to one half")
        try require(Self.normalizedReceiverVolume(-144.0) == 0 && Self.normalizedReceiverVolume(-30.0) == 0 && Self.normalizedReceiverVolume(0.0) == 1, "receiver mute and volume boundaries")
        for invalid: Any in [Double.nan, Double.infinity, -Double.infinity, -145.0, 0.1, "-15", false] {
            try require(Self.normalizedReceiverVolume(invalid) == nil, "invalid initial receiver volume rejected")
        }
        try require(Self.normalizedReceiverVolume(nil) == nil, "missing initial receiver volume stays unknown")
        try require(try Self.receiverVolumeDBFS(0) == -144 && Self.receiverVolumeDBFS(0.5) == -15 && Self.receiverVolumeDBFS(1) == 0, "receiver SET_PARAMETER volume conversion")
        for invalid in [Double.nan, Double.infinity, -0.1, 1.1] {
            var rejected = false
            do { _ = try Self.receiverVolumeDBFS(invalid) } catch NakuAirPlayError.invalid { rejected = true }
            try require(rejected, "out-of-range requested receiver volume rejected")
        }
        let sender = NakuAirPlaySender(address: "127.0.0.1"); sender.audioKey = key; sender.seq = 0x1234; sender.rtp = 0x23456789; sender.ssrc = 7
        let pcm = Data((0..<pcmBytes).map { UInt8($0%4+1) }), packet = try sender.audioPacket(pcm)
        try require(packet.count == 12+pcmBytes+16+8 && packet[0] == 0x80 && packet[1] == 0xE0 && packet.be16(2) == 0x1234, "PCM RTP packet dimensions")
        let opened = try unseal(packet.subdata(in: 12..<packet.count-8), key: key, counter: 0, aad: packet.subdata(in: 4..<12)); try require(opened.count == pcmBytes && opened.prefix(4) == Data([2,1,4,3]), "PCM payload authentication and L16 endian conversion")
        func hex(_ s: String) -> Data { var d = Data(); var i = s.startIndex; while i < s.endIndex { let j = s.index(i, offsetBy: 2); d.append(UInt8(s[i..<j], radix: 16)!); i = j }; return d }
        let fixture = try SRPProof.make(salt: hex("000102030405060708090a0b0c0d0e0f"), server: hex("ecc67eced91a036378e1f9a4969a33051adad472b998e89a3590bae58c543084d7dab8eabcc8dc1c0a2762b9976f141f10e669564636bea36fb4dafc4578677c4a81ce350524dd54048efd7a6405ddca2d3515b92e26e7f7ba285e44d4762091d1117ac807282889be8173f05681c9e52e9748310788c5b5cb95fd2008711aad9a267a6c29a32f81da40f618222042da6b234fbc5ee8cb5030c3028e68c864e8b31ba3e9f4074069590f94036f5c2e5467a9406ed3c8e68c8dd1083362f37827f2b54db7a9bf2fa96fe29186d94ba8c8a3d08c3e1e766067036fbb15a0c9d0b1c5f4ac7ce16f47c2e9309b0708cfa3092baeab4e1515efa29e15d8336d1c085f1e4dbab972397b6a194ea8cf85ac04489af3ebf1430414ed13770c968f7fd5ed3aacb315c3df9ba2ae7c5bf2d1f479785f20001e2588621e1c0e561429a6fa9556ac15d8077883b264ce6a57ed6fc2f7fd98559b4f1279c62f059343228377a28e4928cc4a7b3eb2d9d33482a92cadd1e5373fec62ea577ad857621529816903"), privateKey: hex("0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20"))
        try require(fixture.publicKey == hex("bc0e7cf5dc3babf67dcedbb3b140aacc6cac43f4336b43bbd5de48d6ea7c8eda66924e354255225bccad9debe21182e6bb050f3ff3e6cfbb62c229379968c70ca436ad649a0b051373184215eef046f6f1f2256838f958581f6c7b2b85fa4afe326a0e8a951d4489305331aff88a136fd8d108bcc95fceb7e557c889c828bd23fb0702f053e1ca6470fb3c76bce4843fc005c7ea675740f8550212656cfc8919d9db805a434a68229e0d9dfe43fc16dc680a5ce74b77cf374353b05759bc1da3a9dabde30a4209381c87ca83d9483abdf66b86f9b1cbda9ad82c62712b87ce6fb7069b8fc8df344261821a06d0dc5106af76d4245f3f7737a94dbc484b415555dc401842d3011204553ba9f611b02bc38de26eba1a76bf8350205a62c436ba1c3c7c69d59318bd107fd1c1f5d846b3142e85a5d49e522655e020ed1bfe1e186cf923bf328f0b9b4c6a8aa3266ed9125bb98d63827110713be7803122ee4603c54ea31863ce4b10aff31f9073cf63b94733b4f066e72d4ec35687047d5d0db160") && fixture.sharedKey == hex("e630bac6f2a1f47bb1c03420dd99a546491404a5a0a90146fdab3775a7e36778f9d20a75dc6d6728712db6455c5dd894d3eda560e49075cca34d3ea82590ea98") && fixture.proof == hex("9b68730f513a09bfc189ae640956488fdd06bca049406b360c2e213c69329076bdd0b27191f6cfb560baedfb4ffc5b830df791be689034afdf839eb80bbc247d"), "SRP client matches independent server fixture")
        try require(SRPProof.primeHex.count == 768, "SRP3072 group length")
        sender.state.withLock { sender.running = true }
        sender.writePCM(Data(repeating: 0, count: maximumPCMBytes*3+3))
        try require(sender.pendingPCM.count <= maximumPCMBytes && sender.droppedFrames > 0 && sender.pendingPCM.count%4 == 0, "bounded aligned PCM producer queue")
        sender.state.withLock { sender.running = false }
        var tampered = try HAPFramer(outKey: key, inKey: key).encode(Data("test".utf8)); tampered[tampered.count-1] ^= 1
        var rejected = false
        do { _ = try HAPFramer(outKey: key, inKey: key).decode(tampered) } catch { rejected = true }
        try require(rejected, "tampered control frame is rejected")
        print("PASS: TLV fragmentation/rejection, incremental HAP framing, RTSP framing, event protocol/CSeq/Server echo, control response sequencing, terminal event EOF, failed transport invalidation, receiver volume mapping/validation, PCM RTP dimensions/authentication, SRP group/server fixture, bounded PCM queue, tamper rejection")
    }
}
