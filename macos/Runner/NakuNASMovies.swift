import Foundation
import Security
import CryptoKit
import FlutterMacOS

enum NASMovieError: Error { case configuration, crypto, response, login(Int), expired, keychain }
private final class NASMovieNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
public enum RSAEncryption {
    public static func encrypt(_ text: String, publicKey: String) throws -> String {
        var pem = publicKey
        if !pem.contains("BEGIN"), let data = Data(base64Encoded:pem), let decoded=String(data:data,encoding:.utf8),decoded.contains("BEGIN") { pem=decoded }
        let content=pem.replacingOccurrences(of:"-----BEGIN PUBLIC KEY-----",with:"")
            .replacingOccurrences(of:"-----END PUBLIC KEY-----",with:"")
            .replacingOccurrences(of:"-----BEGIN RSA PUBLIC KEY-----",with:"")
            .replacingOccurrences(of:"-----END RSA PUBLIC KEY-----",with:"")
            .filter { !$0.isWhitespace }
        guard let der=Data(base64Encoded:content) else { throw NASMovieError.crypto }
        let raw=try pkcs1(der)
        let attrs:[String:Any]=[kSecAttrKeyType as String:kSecAttrKeyTypeRSA,kSecAttrKeyClass as String:kSecAttrKeyClassPublic]
        var error:Unmanaged<CFError>?
        guard let key=SecKeyCreateWithData(raw as CFData,attrs as CFDictionary,&error),
              SecKeyIsAlgorithmSupported(key,.encrypt,.rsaEncryptionPKCS1),
              let result=SecKeyCreateEncryptedData(key,.rsaEncryptionPKCS1,Data(text.utf8) as CFData,&error) else { throw NASMovieError.crypto }
        return (result as Data).base64EncodedString()
    }
    /// Security accepts PKCS#1. Strip the standard SubjectPublicKeyInfo wrapper, retaining the inner RSA sequence.
    private static func pkcs1(_ data: Data) throws -> Data {
        let bytes=[UInt8](data)
        func element(_ offset:Int) throws -> (tag:UInt8,start:Int,end:Int,next:Int) {
            guard offset+2<=bytes.count else { throw NASMovieError.crypto }
            var p=offset+1;let first=Int(bytes[p]);p+=1;var count=first
            if first&0x80 != 0 {
                let n=first&0x7f;guard n>0,n<=4,p+n<=bytes.count else { throw NASMovieError.crypto }
                count=0;for b in bytes[p..<p+n] { count=count*256+Int(b) };p+=n
            }
            guard count>=0,p+count<=bytes.count else { throw NASMovieError.crypto }
            return (bytes[offset],p,p+count,p+count)
        }
        let outer=try element(0);guard outer.tag==0x30,outer.end==bytes.count else { throw NASMovieError.crypto }
        let first=try element(outer.start)
        if first.tag==0x02 { return data }
        guard first.tag==0x30 else { throw NASMovieError.crypto }
        let bits=try element(first.next)
        guard bits.tag==0x03,bits.start<bits.end,bytes[bits.start]==0 else { throw NASMovieError.crypto }
        return Data(bytes[(bits.start+1)..<bits.end])
    }
}


// Device-local Keychain entry; no password or session token is returned to Dart.
struct NASMovieCredentials: Codable {
    let address: String
    let username: String
    let password: String
}
struct NASMovieCredentialStore {
    let service: String
    init(service: String = "com.nakutop.naku.nas-movies.credentials") { self.service=service }
    private var query: [String:Any] {
        [kSecClass as String:kSecClassGenericPassword, kSecAttrService as String:service,
         kSecAttrAccount as String:"nas", kSecAttrSynchronizable as String:false]
    }
    func loadValue<T: Decodable>(_ type: T.Type) throws -> T? {
        var q=query; q[kSecReturnData as String]=true; q[kSecMatchLimit as String]=kSecMatchLimitOne
        var item: CFTypeRef?
        let status=SecItemCopyMatching(q as CFDictionary,&item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data=item as? Data else { throw NASMovieError.keychain }
        return try JSONDecoder().decode(type,from:data)
    }
    func saveValue<T: Encodable>(_ credentials: T) throws {
        let data=try JSONEncoder().encode(credentials)
        let attrs:[String:Any]=[kSecValueData as String:data,
            kSecAttrAccessible as String:kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status=SecItemUpdate(query as CFDictionary,attrs as CFDictionary)
        if status == errSecItemNotFound {
            let item=query.merging(attrs,uniquingKeysWith:{ _,new in new })
            guard SecItemAdd(item as CFDictionary,nil) == errSecSuccess else { throw NASMovieError.keychain }
        } else if status != errSecSuccess { throw NASMovieError.keychain }
    }
    func load() throws -> NASMovieCredentials? { try loadValue(NASMovieCredentials.self) }
    func save(_ credentials: NASMovieCredentials) throws { try saveValue(credentials) }
    func forget() throws {
        let status=SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw NASMovieError.keychain }
    }
}

struct NASMovieSavedQR: Codable {
    let address: String, token: String, publicKey: String, staticToken: String, authType: String
    let username: String, serial: String, name: String
    let uid: Int, ugk: Bool
}

private struct NASActivePlayback {
    let id: String, namespace: String
    let socket: URLSessionWebSocketTask
    let heartbeat: Task<Void,Never>
    let closeRequest: URLRequest
}

// A separate, memory-only session. Never imports another application's credentials.
actor NASMovieSession {
    private var base: URL?
    private var token = "", publicKey = "", staticToken = "", authType = "url"
    private var ugk = false
    private var namespace = ""
    private let qrStore = NASMovieCredentialStore(service:"com.nakutop.naku.nas-movies.qr-session")
    private let qrBroker = NASQRBroker()
    private var qrOrigin: URL?
    private var qrDeviceHint = ""
    private var qrGeneration = 0
    private var generation = 0
    private var playbackGeneration = 0
    private var activePlayback: NASActivePlayback?
    private var lanCandidates=[String](),remoteAddress=""
    private var connectionInfoLoaded=false
    private var lastAutoProbe = Date.distantPast
    private var autoSelecting = false
    private let credentialStore = NASMovieCredentialStore()
    private let clientID = UUID().uuidString + "PC-darwin"
    private let session: URLSession
    init(transport: URLSession? = nil) { session=transport ?? Self.makeSession() }
    private static func makeSession() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.httpShouldSetCookies = false; c.urlCache = nil
        c.timeoutIntervalForRequest = 20; c.timeoutIntervalForResource = 30
        return URLSession(configuration: c, delegate: NASMovieNoRedirect(), delegateQueue: nil)
    }
    func logout() {
        playbackGeneration += 1
        if let active=activePlayback {
            active.heartbeat.cancel();active.socket.cancel(with:.normalClosure,reason:nil)
            let transport=session,request=active.closeRequest
            Task {_ = try? await transport.data(for:request)}
        }
        activePlayback=nil;lanCandidates=[];remoteAddress="";connectionInfoLoaded=false
        generation += 1; namespace = ""; base = nil; token = ""; publicKey = ""; staticToken = "" }
    static func origin(_ address: String) throws -> URL {
        guard let u = URL(string: address), u.scheme == "https" || u.scheme == "http",
              u.host != nil, u.user == nil, u.password == nil, u.query == nil, u.fragment == nil,
              u.path.isEmpty || u.path == "/" else { throw NASMovieError.configuration }
        return u
    }
    private func headers() -> [String:String] {
        ["UG-Agent":"PC/WEB", "User-Feature":"Mac", "UG-Client-Id":clientID,
         "Client-Id":clientID, "Client-Version-Str":"1.20.0", "Client-Version":"78579",
         "X-Specify-Language":"zh-CN", "Accept-Language":"zh-CN"]
    }
    private func send(_ url: URL, method: String = "GET", body: [String:Any]? = nil,
                      extra: [String:String] = [:]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url); req.httpMethod = method
        for (k,v) in headers().merging(extra, uniquingKeysWith: { _,new in new }) { req.setValue(v, forHTTPHeaderField:k) }
        if let body { req.httpBody = try JSONSerialization.data(withJSONObject:body); req.setValue("application/json",forHTTPHeaderField:"Content-Type") }
        let (data,res) = try await session.data(for:req)
        guard let http = res as? HTTPURLResponse, http.url?.host == url.host, data.count <= 8*1024*1024 else { throw NASMovieError.response }
        return (data,http)
    }
    private func json(_ data: Data) throws -> [String:Any] {
        guard let o = try JSONSerialization.jsonObject(with:data) as? [String:Any] else { throw NASMovieError.response }
        return o
    }
    private func resolveOrigin(_ address: String) async throws -> URL {
        var origin: URL
        if !address.contains("://"), !address.contains("/") {
            guard address.range(of:"^[a-zA-Z0-9-]{1,63}$",options:.regularExpression) != nil else { throw NASMovieError.configuration }
            let resolver = URL(string:"https://api.ugnas.com/api/p2p/v2/ta/nodeInfo/byAlias")!
            let (bytes,http) = try await send(resolver, method:"POST", body:["alias":address])
            let result = try json(bytes)
            guard http.statusCode == 200, result["code"] as? Int == 200,
                  let d = result["data"] as? [String:Any], let domain = d["relayDomain"] as? String,
                  let alias = d["alias"] as? String, (domain == "ug.link" || domain.hasSuffix(".ug.link")),
                  alias.range(of:"^[a-zA-Z0-9-]{1,63}$",options:.regularExpression) != nil else { throw NASMovieError.response }
            origin = try Self.origin("https://"+alias+"."+domain)
        } else { origin = try Self.origin(address) }
        return origin
    }
    func login(address: String, username: String, password: String, remember: Bool? = nil) async throws -> [String:Any] {
        logout()
        let attempt = generation
        guard !username.isEmpty, !password.isEmpty else { throw NASMovieError.configuration }
        let origin = try await resolveOrigin(address)
        let (challenge,ch) = try await send(origin.appendingPathComponent("ugreen/v1/verify/check"),method:"POST",body:["username":username])
        _ = challenge
        guard ch.statusCode == 200, let encoded = ch.value(forHTTPHeaderField:"X-Rsa-Token"),
              let der = Data(base64Encoded:encoded), let key = String(data:der,encoding:.utf8) else { throw NASMovieError.crypto }
        let (bytes,http) = try await send(origin.appendingPathComponent("ugreen/v1/verify/login"),method:"POST",body:["username":username,"password":try RSAEncryption.encrypt(password,publicKey:key),"keepalive":false,"otp":true,"is_simple":true])
        let result = try json(bytes), code = result["code"] as? Int ?? http.statusCode
        guard http.statusCode == 200, code == 200, let d = result["data"] as? [String:Any] else { throw NASMovieError.login(code) }
        guard let t = d["token"] as? String, !t.isEmpty else { throw NASMovieError.login(d["enable_otp"] as? Bool == true ? 1002 : 401) }
        guard let pk = d["public_key"] as? String, let pkData = Data(base64Encoded:pk), let pem = String(data:pkData,encoding:.utf8) else { throw NASMovieError.crypto }
        guard attempt == generation else { throw NASMovieError.expired }
        base=origin; token=t; publicKey=pem; staticToken=d["static_token"] as? String ?? t
        authType=d["auth_type"] as? String ?? "url"; ugk=d["is_ugk"] as? Bool ?? false
        if let remember {
            if remember { try credentialStore.save(NASMovieCredentials(address:address,username:username,password:password)) }
            else { try credentialStore.forget() }
            try qrStore.forget()
        }
        namespace = Self.namespace(serial:d["sn"] as? String ?? origin.host ?? "", username:username)
        captureConnectionInfo(d)
        return ["name":d["nas_name"] as? String ?? "NAS", "namespace":namespace]
    }
    static func namespace(serial: String, username: String) -> String {
        SHA256.hash(data:Data((serial+"|"+username).utf8)).map { String(format:"%02x",$0) }.joined()
    }
    func savedLogin() throws -> [String:Any] {
        if let saved=try credentialStore.load() { return ["address":saved.address,"username":saved.username] }
        if let saved=try qrStore.loadValue(NASMovieSavedQR.self) { return ["address":saved.address,"username":saved.username,"qr":true] }
        return [:]
    }
    private func loginCacheKey(address: String, username: String) -> String {
        SHA256.hash(data:Data((address+"|"+username).utf8)).map {String(format:"%02x",$0)}.joined()
    }
    static func probeAutoRoute(_ address: String, hint: String, transport: URLSession) async -> String? {
        guard let target=try? origin(address), let host=target.host,
              isPrivateIPv4(host) || (target.scheme == "https" && (host == "ug.link" || host.hasSuffix(".ug.link"))) else {return nil}
        var request=URLRequest(url:target.appendingPathComponent("ugreen/v1/verify/sn"))
        request.timeoutInterval=isPrivateIPv4(host) ? 1.2:3.0
        do {
            let (bytes,response)=try await transport.data(for:request)
            guard let http=response as? HTTPURLResponse,http.statusCode == 200,http.url?.host == host,bytes.count < 65536,
                  let object=try JSONSerialization.jsonObject(with:bytes) as? [String:Any],object["code"] as? Int == 200,
                  let data=object["data"] as? [String:Any],data["sn"] as? String == hint else {return nil}
            return target.absoluteString
        } catch {return nil}
    }
    static func selectAutoRoute(lan: [String], remote: [String], hint: String, transport: URLSession) async -> String? {
        guard !hint.isEmpty else {return nil}
        // Local candidates come only from the authenticated NAS. Probe without
        // sending tokens/passwords; never follow redirects or ignore TLS errors.
        for group in [Array(Set(lan)).sorted(),Array(Set(remote)).sorted()] {
            let selected=await withTaskGroup(of:String?.self,returning:String?.self) { tasks in
                for address in group.prefix(12) {
                    tasks.addTask {await probeAutoRoute(address,hint:hint,transport:transport)}
                }
                for await result in tasks {if let result {tasks.cancelAll();return result}}
                return nil
            }
            if let selected {return selected}
        }
        return nil
    }
    func restore() async throws -> [String:Any] {
        let metadata=try savedLogin(),address=metadata["address"] as? String ?? "",username=metadata["username"] as? String ?? ""
        var selected=address
        let cache=UserDefaults.standard.dictionary(forKey:"NakuNASAutoRouteV1") ?? [:]
        if cache["loginKey"] as? String == loginCacheKey(address:address,username:username),
           let hint=cache["hint"] as? String {
            selected=await Self.selectAutoRoute(lan:cache["lan"] as? [String] ?? [],remote:cache["remote"] as? [String] ?? [],hint:hint,transport:session) ?? address
        }
        let result:[String:Any]
        if let saved=try credentialStore.load() {
            result=try await login(address:selected,username:saved.username,password:saved.password,remember:nil)
        } else if let saved=try qrStore.loadValue(NASMovieSavedQR.self) {
            result=try await adoptQR(NASMovieSavedQR(address:selected,token:saved.token,publicKey:saved.publicKey,staticToken:saved.staticToken,
                authType:saved.authType,username:saved.username,serial:saved.serial,name:saved.name,uid:saved.uid,ugk:saved.ugk),remember:nil)
        } else {throw NASMovieError.expired}
        if selected != address {
            guard cache["namespace"] as? String == namespace else {logout();throw NASMovieError.configuration}
            remoteAddress=(cache["remote"] as? [String])?.first ?? ""
            lanCandidates=cache["lan"] as? [String] ?? []
        }
        return result
    }
    func prepareAutoConnection() async {
        guard !namespace.isEmpty else {return}
        _ = try? await autoConnect(expected:namespace)
    }
    func autoConnect(expected: String, force: Bool = false) async throws -> [String:Any] {
        guard namespace == expected,!namespace.isEmpty,let original=base else {throw NASMovieError.configuration}
        if autoSelecting || (!force && Date().timeIntervalSince(lastAutoProbe)<15) {
            return ["namespace":namespace,"changed":false,"currentAddress":original.absoluteString]
        }
        autoSelecting=true;defer {autoSelecting=false};lastAutoProbe=Date()
        let attempt=generation
        _ = try? await connectionInfo(expected:expected)
        let cache=UserDefaults.standard.dictionary(forKey:"NakuNASAutoRouteV1") ?? [:]
        let hint:String
        if cache["namespace"] as? String == expected,let pinned=cache["hint"] as? String {hint=pinned}
        else if let live=try? await publicDeviceHint(original) {hint=live}
        else {throw NASMovieError.response}
        guard generation == attempt,namespace == expected else {throw NASMovieError.expired}
        let metadata=try savedLogin(),savedAddress=metadata["address"] as? String ?? "",username=metadata["username"] as? String ?? ""
        let remote=[remoteAddress,savedAddress,original.absoluteString].filter {
            guard let u=try? Self.origin($0),let host=u.host else {return false}
            return u.scheme == "https" && (host == "ug.link" || host.hasSuffix(".ug.link"))
        }
        let locals=lanCandidates.filter {guard let u=try? Self.origin($0) else {return false};return Self.isPrivateIPv4(u.host ?? "")}
        UserDefaults.standard.set(["loginKey":loginCacheKey(address:savedAddress,username:username),"namespace":namespace,
            "hint":hint,"lan":locals,"remote":remote],forKey:"NakuNASAutoRouteV1")
        guard let selected=await Self.selectAutoRoute(lan:locals,remote:remote,hint:hint,transport:session),
              generation == attempt,namespace == expected else {return ["namespace":expected,"changed":false,"currentAddress":original.absoluteString]}
        if selected == original.absoluteString {return ["namespace":namespace,"changed":false,"currentAddress":selected]}
        let target=try Self.origin(selected)
        let current=try await api("v1/user/current/user",at:target)
        let machine=try await api("v1/sysinfo/machine/common",parameters:["basic":"1"],at:target)
        guard generation == attempt,namespace == expected,
              let name=current["username"] as? String,let common=machine["common"] as? [String:Any],let serial=common["serial"] as? String,
              Self.namespace(serial:serial,username:name) == expected else {throw NASMovieError.configuration}
        // Commit only after both account and hardware identity are verified.
        // Concurrent catalogue/download requests keep their existing route.
        base=target
        return ["namespace":namespace,"changed":true,"currentAddress":selected]
    }
    func ensure(expected: String) async throws -> [String:Any] {
        if !namespace.isEmpty {
            guard namespace == expected else { throw NASMovieError.configuration }
            do { _ = try await api("v1/user/current/user"); return ["namespace":namespace] }
            catch NASMovieError.expired { /* Reopen saved credentials exactly once. */ }
        }
        let info=try await restore()
        guard namespace == expected else { logout(); throw NASMovieError.configuration }
        return info
    }
    func forget() throws { logout(); try credentialStore.forget(); try qrStore.forget() }
    private func publicDeviceHint(_ target: URL) async throws -> String {
        let (data,http)=try await send(target.appendingPathComponent("ugreen/v1/verify/sn"))
        let r=try json(data)
        guard http.statusCode == 200, r["code"] as? Int == 200,
              let d=r["data"] as? [String:Any], let serial=d["sn"] as? String, !serial.isEmpty else { throw NASMovieError.response }
        return serial
    }
    func createQR(address: String) async throws -> [String:Any] {
        await cancelQR()
        let attempt=qrGeneration
        let target=try await resolveOrigin(address)
        let hint=try await publicDeviceHint(target)
        guard attempt == qrGeneration else { throw NASMovieError.expired }
        qrOrigin=target; qrDeviceHint=hint
        return try await qrBroker.create(alias:"Naku Player",serial:hint)
    }
    func cancelQR() async { qrGeneration += 1; qrOrigin=nil; qrDeviceHint=""; await qrBroker.cancel() }
    func pollQR(remember: Bool) async throws -> [String:Any] {
        guard let target=qrOrigin, !qrDeviceHint.isEmpty else { throw NASMovieError.expired }
        let expected=qrDeviceHint, attempt=qrGeneration
        let state=try await qrBroker.poll()
        guard attempt == qrGeneration else { throw NASMovieError.expired }
        switch state {
        case .waiting: return ["state":"waiting"]
        case .scanned: return ["state":"scanned"]
        case .expired: return ["state":"expired"]
        case .authorized(let p):
            var info=try await adoptQRPayload(p,target:target,expectedDeviceHint:expected,remember:remember,qrAttempt:attempt)
            guard attempt == qrGeneration else { logout(); throw NASMovieError.expired }
            info["state"]="authorized"
            return info
        }
    }
    /// Cloud linkParams may omit account/device hints. The selected NAS itself
    /// must validate its serial and the authorized token before persistence.
    func adoptQRPayload(_ p: [String:Any], target: URL, expectedDeviceHint: String,
                        remember: Bool?, qrAttempt: Int? = nil) async throws -> [String:Any] {
        // /verify/sn is an opaque pre-login routing hint, not the hardware SN.
        guard !expectedDeviceHint.isEmpty, try await publicDeviceHint(target) == expectedDeviceHint else { throw NASQRError.deviceMismatch }
        if let qrAttempt, qrAttempt != qrGeneration { throw NASMovieError.expired }
        guard let t=p["token"] as? String, !t.isEmpty,
              let encodedKey=p["public_key"] as? String, !encodedKey.isEmpty else { throw NASQRError.invalidResponse }
        let pem=Self.qrPublicKey(encodedKey)
        _ = try RSAEncryption.encrypt("naku-qr-key-check",publicKey:pem)
        let saved=NASMovieSavedQR(address:target.absoluteString,token:t,publicKey:pem,
            staticToken:p["static_token"] as? String ?? t,authType:p["auth_type"] as? String ?? "url",
            username:p["username"] as? String ?? "",serial:p["sn"] as? String ?? "",name:p["nas_name"] as? String ?? "NAS",
            uid:Self.qrUID(p["uid"]) ?? -1,ugk:p["is_ugk"] as? Bool ?? false)
        return try await adoptQR(saved,remember:remember,qrAttempt:qrAttempt,discoverAccount:true)
    }
    static func qrUID(_ value: Any?) -> Int? {
        if let value=value as? Int { return value }
        if let value=value as? String { return Int(value) }
        return nil
    }
    static func qrPublicKey(_ value: String) -> String {
        if !value.contains("BEGIN"),let data=Data(base64Encoded:value),let pem=String(data:data,encoding:.utf8),pem.contains("BEGIN") { return pem }
        return value
    }
    private func adoptQR(_ saved: NASMovieSavedQR, remember: Bool?, qrAttempt: Int? = nil,
                         discoverAccount: Bool = false) async throws -> [String:Any] {
        guard discoverAccount || (!saved.username.isEmpty && !saved.serial.isEmpty) else { throw NASQRError.accountMismatch }
        logout(); let attempt=generation
        base=try Self.origin(saved.address); token=saved.token; publicKey=saved.publicKey
        staticToken=saved.staticToken; authType=saved.authType; ugk=saved.ugk
        do {
            let current=try await api("v1/user/current/user")
            guard generation == attempt, qrAttempt == nil || qrAttempt == qrGeneration else { throw NASMovieError.expired }
            guard let username=current["username"] as? String,!username.isEmpty,
                  let uid=Self.qrUID(current["uid"]),uid >= 0,
                  (discoverAccount && saved.username.isEmpty || username == saved.username),
                  saved.uid < 0 || uid == saved.uid else { throw NASQRError.accountMismatch }
            // Authenticate the token against the selected URL, then obtain that
            // NAS's canonical hardware serial. Never use /verify/sn as an SN.
            let machine=try await api("v1/sysinfo/machine/common",parameters:["basic":"1"])
            guard generation == attempt, qrAttempt == nil || qrAttempt == qrGeneration else { throw NASMovieError.expired }
            guard let common=machine["common"] as? [String:Any],let serial=common["serial"] as? String,!serial.isEmpty else { throw NASQRError.invalidResponse }
            guard (discoverAccount && saved.serial.isEmpty) || serial == saved.serial else { throw NASQRError.deviceMismatch }
            let verified=NASMovieSavedQR(address:saved.address,token:saved.token,publicKey:saved.publicKey,
                staticToken:saved.staticToken,authType:saved.authType,username:username,serial:serial,
                name:saved.name,uid:uid,ugk:saved.ugk)
            namespace=Self.namespace(serial:verified.serial,username:verified.username)
            captureConnectionInfo([:])
            if let remember {
                if remember { try qrStore.saveValue(verified) } else { try qrStore.forget() }
                try credentialStore.forget()
            }
            return ["name":verified.name,"namespace":namespace,"username":username]
        } catch { logout(); throw error }
    }
    static func pairingCode(_ raw: String) throws -> String {
        let alphabet=Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        if raw.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            var bytes=[UInt8](repeating:0,count:10)
            guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else {throw NASMovieError.crypto}
            return String(bytes.map {alphabet[Int($0 & 31)]})
        }
        let code=raw.uppercased().filter {!$0.isWhitespace && $0 != "-"}
        guard code.count == 10,code.allSatisfy({alphabet.contains($0)}) else {throw NASMovieError.configuration}
        return code
    }
    // NAS login gates participation; the pairing code selects the existing
    // Syncplay room. No counterpart account entry or NAS-to-NAS binding needed.
    func pairingIdentity(code raw: String) async throws -> [String:Any] {
        if namespace.isEmpty { _ = try await restore() }
        let attempt=generation
        let current=try await api("v1/user/current/user")
        guard generation == attempt,let own=current["username"] as? String,!own.isEmpty,!namespace.isEmpty else {throw NASMovieError.expired}
        let code=try Self.pairingCode(raw)
        let suffix=UUID().uuidString.replacingOccurrences(of:"-",with:"").prefix(4)
        return ["namespace":namespace,"account":own,"pairingCode":code,
                "room":"NP-"+code,"username":"N-"+String(namespace.prefix(8))+"-"+suffix]
    }

    func syncDirectory() async throws -> String {
        let attempt=generation
        guard !namespace.isEmpty else { throw NASMovieError.expired }
        let response=try await fileJSON("v1/filemgr/getHomeShare")
        guard attempt == generation else { throw NASMovieError.expired }
        guard let home=(response["data"] as? [String:Any])?["path"] as? String,
              home.hasPrefix("/"), !home.split(separator:"/").contains("..") else { throw NASMovieError.configuration }
        var path=home
        for name in ["NakuPlayer", "sync-v1", namespace] {
            let next=path+"/"+name
            // Read before create, never turn an arbitrary read failure into an empty library.
            let listing=try await syncList(path:path)
            guard attempt == generation else { throw NASMovieError.expired }
            if !listing.contains(where: { $0["name"] as? String == name }) {
                _ = try await fileJSON("v2/filemgr/createFolder",method:"POST",body:["path":next,"no_recursive_creation":true])
            }
            guard attempt == generation else { throw NASMovieError.expired }
            path=next
        }
        return path
    }
    func syncList(path: String) async throws -> [[String:Any]] {
        let attempt=generation
        var rows=[[String:Any]](),page=1
        while page <= 100 {
            let r=try await fileJSON("v1/filemgr/getDirFileList",method:"POST",body:["path":path+"/","isOnlyFolder":false,"as_dir":false,"limit":200,"page":page,"reverse":false,"sort_type":1])
            guard attempt == generation else { throw NASMovieError.expired }
            guard let d=r["data"] as? [String:Any],let files=d["files"] as? [[String:Any]] else { throw NASMovieError.response }
            rows += files
            if files.count < 200 { return rows }
            page += 1
        }
        throw NASMovieError.response
    }
    func syncRead(path: String) async throws -> Data {
        let attempt=generation
        guard let base,!token.isEmpty else { throw NASMovieError.expired }
        var u=URLComponents(url:base.appendingPathComponent("ugreen/v1/filemgr/downloadFile"),resolvingAgainstBaseURL:false)!
        u.queryItems=[URLQueryItem(name:"paths",value:path),URLQueryItem(name:"token",value:token),URLQueryItem(name:"coding",value:"true")]
        let (bytes,http)=try await send(u.url!,extra:["Range":"bytes=0-8388607"])
        guard attempt == generation else { throw NASMovieError.expired }
        guard [200,206].contains(http.statusCode),bytes.count <= 8*1024*1024 else { throw NASMovieError.response }
        return bytes
    }
    func syncUpload(directory: String, name: String, bytes: Data) async throws {
        let attempt=generation
        guard let base,!token.isEmpty,bytes.count <= 8*1024*1024,
              name.range(of:"^[a-zA-Z0-9-]+\\.json$",options:.regularExpression) != nil else { throw NASMovieError.configuration }
        var u=URLComponents(url:base.appendingPathComponent("ugreen/v1/filemgr/fileUpload"),resolvingAgainstBaseURL:false)!
        var h=headers()
        if authType == "header" { h["X-Ugreen-Token"]=try RSAEncryption.encrypt(token,publicKey:publicKey) }
        else { u.queryItems=[URLQueryItem(name:"token",value:token)] }
        h["X-Ugreen-Security-Key"]=Insecure.MD5.hash(data:Data(token.utf8)).map { String(format:"%02x",$0) }.joined()
        let boundary="Naku"+UUID().uuidString.replacingOccurrences(of:"-",with:"")
        let uuid=UUID().uuidString
        func form(first: Bool, content: Data) -> Data {
            var body=Data()
            let fields=["uuid":uuid,"dir":directory,"action_type":"0","size":String(bytes.count),"begin_size":"0","current_size":String(content.count),"change_time":String(Int(Date().timeIntervalSince1970)),"filename":name,"resume":"true","first_request":first ? "true":"false"]
            for (key,value) in fields { body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(key)\"\r\n\r\n\(value)\r\n".utf8)) }
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(name)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8));body.append(content)
            body.append(Data("\r\n--\(boundary)--\r\n".utf8));return body
        }
        for first in [true,false] {
            guard attempt == generation else { throw NASMovieError.expired }
            var req=URLRequest(url:u.url!);req.httpMethod="POST";req.httpBody=form(first:first,content:first ? Data():bytes)
            for (key,value) in h { req.setValue(value,forHTTPHeaderField:key) }
            req.setValue("multipart/form-data; boundary="+boundary,forHTTPHeaderField:"Content-Type")
            let (data,response)=try await session.data(for:req)
            guard attempt == generation else { throw NASMovieError.expired }
            guard let http=response as? HTTPURLResponse,http.statusCode == 200,data.count <= 1024*1024 else { throw NASMovieError.response }
            let result=try json(data),code=result["code"] as? Int ?? 0
            guard code == 200 else { throw NASMovieError.login(code) }
        }
        let readback=try await syncRead(path:directory+"/"+name)
        guard attempt == generation else { throw NASMovieError.expired }
        guard readback == bytes else { throw NASMovieError.response }
    }
    func syncPull(expected: String) async throws -> [String:Any] {
        _ = try await ensure(expected:expected)
        let attempt=generation
        guard namespace == expected else { throw NASMovieError.configuration }
        let dir=try await syncDirectory(),files=try await syncList(path:dir)
        guard attempt == generation else { throw NASMovieError.expired }
        var latest=[String:(Int,String)]()
        for file in files {
            guard let name=file["name"] as? String,name.range(of:"^[a-f0-9-]{36}-[0-9]{12}\\.json$",options:.regularExpression) != nil else { continue }
            let device=String(name.prefix(36)),seq=Int(name.dropFirst(37).dropLast(5)) ?? 0
            if seq > (latest[device]?.0 ?? -1) { latest[device]=(seq,name) }
        }
        guard latest.count <= 100 else { throw NASMovieError.response }
        var documents=[String]()
        for (_,item) in latest.sorted(by:{$0.key < $1.key}) {
            guard attempt == generation else { throw NASMovieError.expired }
            let bytes=try await syncRead(path:dir+"/"+item.1)
            guard attempt == generation else { throw NASMovieError.expired }
            guard let text=String(data:bytes,encoding:.utf8) else { throw NASMovieError.response }
            documents.append(text)
        }
        return ["documents":documents,"path":dir]
    }
    func syncPush(expected: String, device: String, sequence: Int, document: String) async throws -> [String:Any] {
        _ = try await ensure(expected:expected)
        let attempt=generation
        guard namespace == expected else { throw NASMovieError.configuration }
        guard device.range(of:"^[a-f0-9-]{36}$",options:.regularExpression) != nil,sequence > 0,sequence < 1000000000000 else { throw NASMovieError.configuration }
        let dir=try await syncDirectory(),name=device+"-"+String(format:"%012lld",Int64(sequence))+".json",bytes=Data(document.utf8)
        // Immutable revisions: another device can never overwrite this writer.
        guard attempt == generation else { throw NASMovieError.expired }
        let files=try await syncList(path:dir)
        guard attempt == generation else { throw NASMovieError.expired }
        if files.contains(where:{$0["name"] as? String == name}) {
            guard try await syncRead(path:dir+"/"+name) == bytes else { throw NASMovieError.response }
        } else { try await syncUpload(directory:dir,name:name,bytes:bytes) }
        guard attempt == generation else { throw NASMovieError.expired }
        // Keep recent verified revisions of this writer. Other devices and
        // arbitrary files are never included in housekeeping.
        try? await syncPrune(directory:dir,device:device,sequence:sequence)
        return ["path":dir+"/"+name]
    }
    func syncPrune(directory: String, device: String, sequence: Int) async throws {
        let attempt=generation
        guard device.range(of:"^[a-f0-9-]{36}$",options:.regularExpression) != nil else { throw NASMovieError.configuration }
        let files=try await syncList(path:directory)
        guard attempt == generation else { throw NASMovieError.expired }
        let old=files.compactMap { file -> String? in
            guard let name=file["name"] as? String,name.hasPrefix(device+"-"),
                  name.count == 54,name.hasSuffix(".json"),
                  let seq=Int(name.dropFirst(37).dropLast(5)),seq > 0,seq <= sequence-10 else { return nil }
            return directory+"/"+name
        }
        if !old.isEmpty {
            _ = try await fileJSON("v2/filemgr/delPaths",method:"POST",body:["paths":old,"forever":true])
        }
    }
    // Ordinary file-manager endpoints use session auth, without movie AES wrapping.
    func fileJSON(_ route: String, method: String = "GET", parameters: [String:String] = [:], body: [String:Any]? = nil) async throws -> [String:Any] {
        guard let base, !token.isEmpty else { throw NASMovieError.expired }
        var p=parameters, h=headers()
        h["X-Ugreen-Security-Key"]=Insecure.MD5.hash(data:Data(token.utf8)).map { String(format:"%02x",$0) }.joined()
        if authType == "header" { h["X-Ugreen-Token"]=try RSAEncryption.encrypt(token,publicKey:publicKey) } else { p["token"]=token }
        var u=URLComponents(url:base.appendingPathComponent("ugreen/"+route),resolvingAgainstBaseURL:false)!
        u.queryItems=p.map { URLQueryItem(name:$0.key,value:$0.value) }
        let (bytes,http)=try await send(u.url!,method:method,body:body,extra:h)
        let result=try json(bytes),code=result["code"] as? Int ?? http.statusCode
        guard http.statusCode == 200,code == 200 else { throw NASMovieError.login(code) }
        return result
    }
    func restoreAt(address: String, expected: String, remember: Bool) async throws -> [String:Any] {
        guard expected.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else {throw NASMovieError.configuration}
        let target=try Self.origin(address)
        guard target.scheme != "http" || Self.isPrivateIPv4(target.host ?? "") else {throw NASMovieError.configuration}
        let previousRemote=namespace == expected ? remoteAddress:"",previousLAN=namespace == expected ? lanCandidates:[]
        do {
            let result:[String:Any]
            if let saved=try credentialStore.load() {
                result=try await login(address:address,username:saved.username,password:saved.password,remember:nil)
                guard namespace == expected else {throw NASMovieError.configuration}
                if remember {try credentialStore.save(NASMovieCredentials(address:address,username:saved.username,password:saved.password))}
                else {try credentialStore.forget()}
                try qrStore.forget()
            } else if let saved=try qrStore.loadValue(NASMovieSavedQR.self) {
                let moved=NASMovieSavedQR(address:address,token:saved.token,publicKey:saved.publicKey,staticToken:saved.staticToken,
                    authType:saved.authType,username:saved.username,serial:saved.serial,name:saved.name,uid:saved.uid,ugk:saved.ugk)
                result=try await adoptQR(moved,remember:nil)
                guard namespace == expected else {throw NASMovieError.configuration}
                if remember {try qrStore.saveValue(moved)}else{try qrStore.forget()}
                try credentialStore.forget()
            } else {throw NASMovieError.expired}
            if remoteAddress.isEmpty {remoteAddress=previousRemote}
            for candidate in previousLAN where !lanCandidates.contains(candidate) {lanCandidates.append(candidate)}
            return result
        } catch {logout();throw error}
    }
    static func isPrivateIPv4(_ value: String) -> Bool {
        let parts=value.split(separator:".",omittingEmptySubsequences:false)
        guard parts.count == 4,parts.allSatisfy({!$0.isEmpty && $0.allSatisfy({$0.isNumber && $0.isASCII})}),
              parts.allSatisfy({$0.count == 1 || !$0.hasPrefix("0")}) else {return false}
        let numbers=parts.compactMap{Int($0)}
        guard numbers.count == 4,numbers.allSatisfy({$0 >= 0 && $0 <= 255}) else {return false}
        return numbers[0] == 10 || numbers[0] == 192 && numbers[1] == 168 || numbers[0] == 172 && (16...31).contains(numbers[1])
    }
    static func connectionCandidates(_ info: [String:Any]) -> [String] {
        var hosts=[String]()
        for key in ["ipv_4","ipv4"] {hosts += info[key] as? [String] ?? []}
        hosts += (info["network_info"] as? [[String:Any]] ?? []).compactMap{$0["ip"] as? String}
        if let ip=info["ip"] as? String {hosts.append(ip)}
        let https=playbackNumber(info["https_port"]),http=playbackNumber(info["http_port"])
        var result=[String]()
        for host in hosts where isPrivateIPv4(host) {
            for (scheme,port) in [("https",https),("http",http)] {
                guard let port,(1...65535).contains(port) else {continue}
                let candidate="\(scheme)://\(host):\(port)"
                if !result.contains(candidate) {result.append(candidate)}
            }
        }
        return result
    }
    private func captureConnectionInfo(_ info: [String:Any]) {
        for candidate in Self.connectionCandidates(info) where !lanCandidates.contains(candidate) {lanCandidates.append(candidate)}
        if let base,let host=base.host {
            if Self.isPrivateIPv4(host) {
                if !lanCandidates.contains(base.absoluteString) {lanCandidates.insert(base.absoluteString,at:0)}
            } else if host == "ug.link" || host.hasSuffix(".ug.link") {remoteAddress=base.absoluteString}
        }
    }
    func connectionInfo(expected: String? = nil, refresh: Bool = false) async throws -> [String:Any] {
        if let expected,!expected.isEmpty,expected != namespace {throw NASMovieError.configuration}
        guard !namespace.isEmpty else {return [:]}
        let attempt=generation
        if refresh || !connectionInfoLoaded {
            // This is the exact endpoint used by UGOS to advertise LAN ports.
            // Auto routing verifies the unauthenticated device hint before sending session credentials.
            do {
                let response=try await fileJSON("v1/user/priority_link")
                guard attempt == generation else {throw NASMovieError.expired}
                let data=response["data"] as? [String:Any] ?? [:]
                captureConnectionInfo(data);connectionInfoLoaded=true
                if remoteAddress.isEmpty,let advertised=data["uglink_domain"] as? String {
                    // Firmware advertises either an UGlink host or ug.link/<alias>.
                    let value=advertised.contains("://") ? advertised:"https://"+advertised
                    if let link=URLComponents(string:value),link.host == "ug.link" {
                        let components=link.path.split(separator:"/")
                        if components.count == 1 {
                            let alias=String(components[0])
                            if alias.range(of:"^[a-zA-Z0-9-]{1,63}$",options:.regularExpression) != nil {
                                let resolved=try await resolveOrigin(alias)
                                guard attempt == generation else {throw NASMovieError.expired}
                                remoteAddress=resolved.absoluteString
                            }
                        }
                    } else if let origin=try? Self.origin(value),let host=origin.host,host.hasSuffix(".ug.link"),origin.scheme == "https" {remoteAddress=origin.absoluteString}
                }
            } catch {
                guard attempt == generation else {throw NASMovieError.expired}
                // Older firmware may omit discovery; manual address login still works.
            }
        }
        return ["currentAddress":base?.absoluteString ?? "","remoteAddress":remoteAddress,"lanCandidates":lanCandidates,
                "mode":Self.isPrivateIPv4(base?.host ?? "") ? "local":"remote","namespace":namespace]
    }

    // Playback URLs and task credentials are session-only, separate from download assets.
    private func playbackInput(expected: String, id: Int, library: Int, path: String) throws {
        guard !namespace.isEmpty, namespace == expected, id > 0, library > 0,
              path.hasPrefix("/"), !path.split(separator:"/").contains(".."),
              !path.contains("\0") else { throw NASMovieError.configuration }
    }
    private func playbackURL(_ route: String, parameters: [String:String]) throws -> URL {
        guard let base, !token.isEmpty else { throw NASMovieError.expired }
        var u=URLComponents(url:base.appendingPathComponent("ugreen/"+route),resolvingAgainstBaseURL:false)!
        var p=parameters; p["token"]=token
        u.queryItems=p.sorted{$0.key < $1.key}.map{URLQueryItem(name:$0.key,value:$0.value)}
        u.percentEncodedQuery=u.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
        guard let url=u.url else { throw NASMovieError.configuration };return url
    }
    private func playbackCloseRequest(task: String) throws -> URLRequest {
        var request=URLRequest(url:try playbackURL("v2/stream/transcode/web/close",parameters:[:]))
        request.httpMethod="POST";request.httpBody=try JSONSerialization.data(withJSONObject:playbackParameters(task))
        for (key,value) in headers() {request.setValue(value,forHTTPHeaderField:key)}
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        return request
    }
    private func playbackParameters(_ task: String) -> [String:Any] {
        ["task_id":task,"timestamp":String(Int(Date().timeIntervalSince1970*1000)),"src_type":2]
    }
    private func playbackQuery(_ task: String) -> [String:String] {
        ["task_id":task,"timestamp":String(Int(Date().timeIntervalSince1970*1000)),"src_type":"2"]
    }
    private static func playbackNumber(_ value: Any?) -> Int? {
        if let number=value as? Int {return number};if let text=value as? String {return Int(text)};return nil
    }
    static func playbackProfileData(_ info: [String:Any]) throws -> [[String:Any]] {
        guard let raw=info["transcodeable"] as? [[String:Any]],!raw.isEmpty,raw.count <= 32 else {throw NASMovieError.response}
        let original=(info["resolution"] as? [String:Any])?["name"] as? String
        var seen=Set<String>()
        return try raw.map {item in
            guard let id=item["resolution"] as? String,
                  id.range(of:"^[0-9]{1,5}x[0-9]{1,5}$",options:.regularExpression) != nil,
                  seen.insert(id).inserted,let name=item["name"] as? String,!name.isEmpty else {throw NASMovieError.response}
            return ["id":id,"label":name,"isOriginal":name == original]
        }
    }
    static func playbackTrackData(_ value: Any?, subtitles: Bool) -> [[String:Any]] {
        var result:[[String:Any]]=subtitles ? [["id":-1,"label":"关闭字幕","language":"","isDefault":false,"isText":true]] : []
        var seen=Set<Int>()
        for item in (value as? [[String:Any]] ?? []).prefix(256) {
            guard let id=playbackNumber(item["id"]),id >= 0,seen.insert(id).inserted else {continue}
            let name=(item["title"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? (item["language"] as? String) ?? "轨道 \(id)"
            result.append(["id":id,"label":name,"language":item["raw_language"] as? String ?? "",
                           "isDefault":playbackNumber(item["isDefault"]) == 1 || item["isDefault"] as? Bool == true,
                           "isText":!subtitles || playbackNumber(item["is_text"]) == 1 || item["is_text"] as? Bool == true])
        }
        return result
    }
    private func playbackInfo(path: String, task: String) async throws -> [String:Any] {
        var body=playbackParameters(task);body["video_path"]=path;body["is_net_disk_direct"]=false
        let response=try await fileJSON("v2/stream/transcode/web/info",method:"POST",body:body)
        guard let data=response["data"] as? [String:Any] else {throw NASMovieError.response};return data
    }
    private func cleanupPlayback(_ request: URLRequest) async {
        // A captured request can close only this task even if the account changes.
        _ = try? await session.data(for:request)
    }
    func playbackOptions(expected: String, id: Int, library: Int, path: String) async throws -> [String:Any] {
        _ = try await ensure(expected:expected)
        try playbackInput(expected:expected,id:id,library:library,path:path)
        let attempt=generation,task=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        let close=try playbackCloseRequest(task:task)
        do {
            let info=try await playbackInfo(path:path,task:task)
            guard attempt == generation,namespace == expected else {throw NASMovieError.expired}
            let profiles=try Self.playbackProfileData(info)
            let answer:[String:Any] = ["profiles":profiles,"audios":Self.playbackTrackData(info["audios"],subtitles:false),
                 "subtitles":Self.playbackTrackData(info["subtitles"],subtitles:true),
                 "durationMs":Self.playbackNumber(info["duration"]) ?? 0,"width":Self.playbackNumber(info["width"]) ?? 0,
                 "height":Self.playbackNumber(info["height"]) ?? 0,"originHost":base?.host ?? "",
                 "isRelayOrigin":base?.host?.hasSuffix(".ug.link") ?? false]
            await cleanupPlayback(close)
            guard attempt == generation,namespace == expected else {throw NASMovieError.expired}
            return answer
        } catch {await cleanupPlayback(close);throw error}
    }
    func startPlayback(expected: String, id: Int, library: Int, path: String,
                       resolution: String?, audio: Int?, subtitle: Int?) async throws -> [String:Any] {
        _ = try await ensure(expected:expected)
        try playbackInput(expected:expected,id:id,library:library,path:path)
        playbackGeneration += 1;let playAttempt=playbackGeneration,attempt=generation
        let task=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        // Capture cleanup auth before suspension, so account changes cannot retarget it.
        let ownClose=try playbackCloseRequest(task:task)
        do {
            let info=try await playbackInfo(path:path,task:task)
            guard attempt == generation,playAttempt == playbackGeneration,namespace == expected else {throw NASMovieError.expired}
            let profiles=try Self.playbackProfileData(info),audios=Self.playbackTrackData(info["audios"],subtitles:false),subtitles=Self.playbackTrackData(info["subtitles"],subtitles:true)
            let selected=resolution ?? (profiles.last?["id"] as? String ?? "")
            guard profiles.contains(where:{$0["id"] as? String == selected}),
                  audio == nil || audios.contains(where:{$0["id"] as? Int == audio}),
                  subtitle == nil || subtitles.contains(where:{$0["id"] as? Int == subtitle}),
                  let redir=info["redir_link"] as? String,let parts=URLComponents(string:redir),
                  let name=parts.queryItems?.first(where:{$0.name == "video_name"})?.value,
                  !name.isEmpty,name.count < 1024,!name.contains("/"),!name.contains("\\"),!name.contains("..") else {throw NASMovieError.configuration}
            let audioID=audio ?? (audios.first(where:{$0["isDefault"] as? Bool == true})?["id"] as? Int) ?? (audios.first?["id"] as? Int) ?? -1
            let subtitleID=subtitle ?? -1,file=name+"_"+selected+".m3u8"
            var query=playbackQuery(task);query.merge(["m3u8_file":file,"regen":"1","subtitle_index":String(subtitleID),"audio_index":String(audioID),"prefer_h265":"false"],uniquingKeysWith:{$1})
            let response=try await fileJSON("v2/stream/transcode/web/play",parameters:query)
            guard attempt == generation,playAttempt == playbackGeneration,namespace == expected else {throw NASMovieError.expired}
            var mediaQuery=playbackQuery(task);mediaQuery["m3u8_file"]=file
            let url=try playbackURL("v2/stream/transcode/web/m3u8",parameters:mediaQuery)
            let socketURL=try playbackURL("v2/stream/transcode/ws",parameters:[:]);var components=URLComponents(url:socketURL,resolvingAgainstBaseURL:false)!
            components.scheme=socketURL.scheme == "https" ? "wss":"ws"
            var request=URLRequest(url:components.url!);for (key,value) in headers() {request.setValue(value,forHTTPHeaderField:key)}
            let socket=session.webSocketTask(with:request);socket.resume()
            let old=activePlayback;old?.heartbeat.cancel();old?.socket.cancel(with:.normalClosure,reason:nil)
            if let old {await cleanupPlayback(old.closeRequest)}
            guard attempt == generation,playAttempt == playbackGeneration,namespace == expected else {socket.cancel(with:.normalClosure,reason:nil);throw NASMovieError.expired}
            let heartbeat=Task {
                while !Task.isCancelled {
                    let payload:[String:Any] = ["cmd":"ping","timestamp":Int(Date().timeIntervalSince1970*1000),"task_id":task,"data":[:]]
                    if let data=try? JSONSerialization.data(withJSONObject:payload),let text=String(data:data,encoding:.utf8) {try? await socket.send(.string(text))}
                    do {try await Task.sleep(nanoseconds:10_000_000_000)}catch{break}
                }
            }
            activePlayback=NASActivePlayback(id:task,namespace:expected,socket:socket,heartbeat:heartbeat,closeRequest:ownClose)
            return ["url":url.absoluteString,"headers":[:],"taskId":task,"resolution":selected,
                    "audio":audioID,"subtitle":subtitleID,"bitrateBps":(response["data"] as? [String:Any])?["bitrate_bps"] ?? 0,"source":"nas-hls"]
        } catch {await cleanupPlayback(ownClose);throw error}
    }
    func closePlayback(task: String, expected: String? = nil) async {
        guard let active=activePlayback,active.id == task,expected == nil || expected == active.namespace else {return}
        activePlayback=nil;playbackGeneration += 1;active.heartbeat.cancel()
        active.socket.cancel(with:.normalClosure,reason:nil)
        await cleanupPlayback(active.closeRequest)
    }

    func collection(id: String, library: Int) async throws -> [String:Any] {
        guard !id.isEmpty, library > 0 else { throw NASMovieError.configuration }
        var rows=[[String:Any]](), total: Int?, page=1
        var previousPage: Data?
        while page <= 500 {
            let data=try await api("v1/video/collection/getCollectionContent",parameters:["collection_id":id,"media_lib_set_id":String(library),"sort_type":"0","order_type":"2","page":String(page),"page_size":"200"])
            let raw=data["video_arr"] as? [[String:Any]] ?? []
            let fingerprint=try JSONSerialization.data(withJSONObject:raw,options:.sortedKeys)
            // A server ignoring page must never produce an inflated count.
            if fingerprint == previousPage { throw NASMovieError.configuration }
            previousPage=fingerprint
            rows += raw.compactMap { $0["video_info"] as? [String:Any] }
            if let value=data["total_num"] as? Int { total=value }
            else if let value=data["total_num"] as? String { total=Int(value) }
            if let total, rows.count >= total { break }
            if raw.isEmpty || data["is_last_page"] as? Bool == true || (total == nil && raw.count < 200) { break }
            page += 1
        }
        guard page <= 500 else { throw NASMovieError.configuration }
        return ["video_arr":rows,"total_num":total ?? rows.count]
    }
    func api(_ route: String, parameters: [String:String] = [:], at target: URL? = nil) async throws -> [String:Any] {
        guard let base = target ?? base, !token.isEmpty else { throw NASMovieError.expired }
        let key = UUID().uuidString.replacingOccurrences(of:"-",with:"")
        var params = parameters, h = headers()
        h["X-Ugreen-Security-Key"] = Insecure.MD5.hash(data:Data(token.utf8)).map { String(format:"%02x",$0) }.joined()
        h["X-Ugreen-Security-Code"] = try RSAEncryption.encrypt(key,publicKey:publicKey)
        if authType == "header" { h["X-Ugreen-Token"] = try RSAEncryption.encrypt(token,publicKey:publicKey) } else { params["token"] = token }
        var q = URLComponents(); q.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name:$0.key,value:$0.value) }
        let encrypted = try AES.GCM.seal(Data((q.percentEncodedQuery ?? "").replacingOccurrences(of:"+",with:"%2B").utf8),using:SymmetricKey(data:Data(key.utf8)))
        guard let combined = encrypted.combined else { throw NASMovieError.crypto }
        var u = URLComponents(url:base.appendingPathComponent("ugreen/"+route),resolvingAgainstBaseURL:false)!
        u.queryItems=[URLQueryItem(name:"encrypt_query",value:combined.base64EncodedString())]
        u.percentEncodedQuery = u.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
        let (bytes,http) = try await send(u.url!,extra:h)
        var result = try json(bytes)
        if let text=result["encrypt_resp_body"] as? String, let data=Data(base64Encoded:text) {
            result = try json(AES.GCM.open(AES.GCM.SealedBox(combined:data),using:SymmetricKey(data:Data(key.utf8))))
        }
        let code=result["code"] as? Int ?? http.statusCode
        if [401,403,9902].contains(code) { if target == nil {logout()}; throw NASMovieError.expired }
        guard http.statusCode == 200, code == 200 else { throw NASMovieError.login(code) }
        return result["data"] as? [String:Any] ?? [:]
    }
    func libraries() async throws -> [String:Any] { try await api("v1/video/media_lib/get_all",parameters:["mediaLib_get_all_req_type":"1","language":"zh-CN"]) }
    func catalog(page: Int, library: Int, keyword: String) async throws -> [String:Any] {
        if !keyword.isEmpty {
            let result = try await api("v1/video/search",parameters:["search_type":"1","offset":String((page-1)*40),"limit":"40","keyword":keyword,"language":"zh-CN"])
            let groups = [result["movies_list"], result["tv_list"]].compactMap { $0 as? [String:Any] }
            return ["video_arr":groups.flatMap { $0["video_arr"] as? [[String:Any]] ?? [] },
                    "total_num":groups.reduce(0) { $0 + ($1["total_num"] as? Int ?? 0) },
                    "is_last_page":groups.allSatisfy { $0["is_last_page"] as? Bool ?? true }]
        }
        return try await api(library > 0 ? "v2/video/mediaLibSet/poster-wall" : "v1/video/all",parameters:["media_lib_set_id":String(library),"page":String(page),"page_size":"40","language":"zh-CN","classification":String(library > 0 ? library : -101),"sort_type":"2","order_type":"2","release_date_begin":"-9999999999","release_date_end":"-9999999999","identify_status":"0","watch_status":"-1","ug_style_id":"0","ug_country_id":"0","clarity":"-1"])
    }
    func details(id: Int, library: Int, tv: Bool) async throws -> [String:Any] {
        guard id > 0, library > 0 else { throw NASMovieError.configuration }
        return try await api(tv ? "v2/video/details/getTV" : "v1/video/details/getMovie",parameters:tv ? ["ug_video_info_id":String(id)] : ["id":String(id),"media_lib_set_id":String(library),"fileVersion":"true"])
    }
    func asset(path: String, id: Int, poster: Bool, library: Int) throws -> String {
        guard let base, !token.isEmpty, !path.isEmpty else { throw NASMovieError.expired }
        var u=URLComponents(url:base.appendingPathComponent(poster ? "ugreen/v2/video/getImaStream" : "ugreen/v1/video/details/downloadOriginalFile"),resolvingAgainstBaseURL:false)!
        var p = poster ? ["app_name":"web","name":path,"size":"1","id":String(id)] : ["paths":path,"id":String(id),"media_lib_set_id":String(library)]
        p[poster && ugk ? "ugk" : "token"] = poster && ugk ? staticToken : token
        u.queryItems=p.map { URLQueryItem(name:$0.key,value:$0.value) }
        u.percentEncodedQuery = u.percentEncodedQuery?.replacingOccurrences(of:"+",with:"%2B")
        return u.url!.absoluteString
    }
}

final class NakuNASMovies {
    private let session = NASMovieSession()
    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args=call.arguments as? [String:Any] ?? [:]
        Task {
            do {
                let value: Any?
                if ["libraries","catalog","details","collection","playbackOptions","syncPull","syncPush","asset"].contains(call.method) {
                    await session.prepareAutoConnection()
                }
                switch call.method {
                case "login": value=try await session.login(address:args["address"] as? String ?? "",username:args["username"] as? String ?? "",password:args["password"] as? String ?? "",remember:args["remember"] as? Bool ?? false)
                case "qrCreate": value=try await session.createQR(address:args["address"] as? String ?? "")
                case "qrPoll": value=try await session.pollQR(remember:args["remember"] as? Bool ?? false)
                case "qrCancel": await session.cancelQR(); value=nil
                case "ensure": value=try await session.ensure(expected:args["namespace"] as? String ?? "")
                case "autoConnect": value=try await session.autoConnect(expected:args["namespace"] as? String ?? "",force:args["force"] as? Bool ?? false)
                case "pairingIdentity": value=try await session.pairingIdentity(code:args["code"] as? String ?? "")
                case "syncPull": value=try await session.syncPull(expected:args["namespace"] as? String ?? "")
                case "syncPush": value=try await session.syncPush(expected:args["namespace"] as? String ?? "",device:args["device"] as? String ?? "",sequence:args["sequence"] as? Int ?? 0,document:args["document"] as? String ?? "")
                case "restoreAt": value=try await session.restoreAt(address:args["address"] as? String ?? "",expected:args["namespace"] as? String ?? "",remember:args["remember"] as? Bool ?? false)
                case "connectionInfo": value=try await session.connectionInfo(expected:args["namespace"] as? String,refresh:args["refresh"] as? Bool ?? false)
                case "playbackOptions": value=try await session.playbackOptions(expected:args["namespace"] as? String ?? "",id:args["id"] as? Int ?? 0,library:args["library"] as? Int ?? 0,path:args["path"] as? String ?? "")
                case "startPlayback": value=try await session.startPlayback(expected:args["namespace"] as? String ?? "",id:args["id"] as? Int ?? 0,library:args["library"] as? Int ?? 0,path:args["path"] as? String ?? "",resolution:args["resolution"] as? String,audio:args["audio"] as? Int,subtitle:args["subtitle"] as? Int)
                case "closePlayback": await session.closePlayback(task:args["taskId"] as? String ?? "",expected:args["namespace"] as? String);value=[:]
                case "collection": value=try await session.collection(id:args["id"] as? String ?? "",library:args["library"] as? Int ?? 0)
                case "savedLogin": value=try await session.savedLogin()
                case "restore": value=try await session.restore()
                case "forget": try await session.forget(); value=nil
                case "logout": await session.cancelQR(); await session.logout(); value=nil
                case "libraries": value=try await session.libraries()
                case "catalog": value=try await session.catalog(page:args["page"] as? Int ?? 1,library:args["library"] as? Int ?? 0,keyword:args["keyword"] as? String ?? "")
                case "details": value=try await session.details(id:args["id"] as? Int ?? 0,library:args["library"] as? Int ?? 0,tv:args["tv"] as? Bool ?? false)
                case "asset": value=try await session.asset(path:args["path"] as? String ?? "",id:args["id"] as? Int ?? 0,poster:args["poster"] as? Bool ?? false,library:args["library"] as? Int ?? 0)
                default: await MainActor.run { result(FlutterMethodNotImplemented) }; return
                }
                await MainActor.run { result(value) }
            } catch {
                // URLSession errors can contain authenticated URLs. Never forward descriptions.
                let message: String
                switch error {
                case NASMovieError.login(let code): message = code == 1003 ? "账号或密码不正确，请重新输入。" : "NAS 返回错误（\(code)）；请检查账号权限或验证要求。"
                case NASMovieError.expired: message = "NAS 会话已过期，请退出后重新登录。"
                case NASMovieError.keychain: message = "无法访问 macOS 钥匙串，请解锁钥匙串后重试。"
                case NASMovieError.configuration: message = "NAS 资源或设备身份不匹配，请重新打开对应 NAS 的影视中心。"
                case let qr as NASQRError: message = qr.localizedDescription
                default: message = "NAS 请求失败，请检查网络、证书及 NAS 是否在线。"
                }
                await MainActor.run { result(FlutterError(code:"nas",message:message,details:nil)) }
            }
        }
    }
}
