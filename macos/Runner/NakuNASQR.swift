import Foundation
import Security

/// Values stay native; only the QR URL is intended for presentation in Flutter.
enum NASQRResult {
    case waiting
    case scanned
    case expired
    case authorized([String: Any])
}

enum NASQRError: Error, LocalizedError {
    case cancelled, cryptography, invalidResponse, rejected(Int, String), unexpectedLoginType, deviceMismatch, accountMismatch
    var errorDescription: String? {
        switch self {
        case .cancelled: return "扫码登录已取消，请刷新二维码。"
        case .cryptography: return "无法创建或解密扫码登录密钥，请刷新二维码。"
        case .invalidResponse: return "绿联云扫码登录响应不完整，请刷新重试。"
        case .rejected(let code, let message): return "绿联云扫码登录错误（\(code)）：\(message)"
        case .deviceMismatch: return "扫码授权的 NAS 与当前地址不一致，请选择对应设备后重新扫码。"
        case .accountMismatch: return "扫码账号与 NAS 验证的账号不一致，请刷新二维码重新授权。"
        case .unexpectedLoginType: return "二维码未返回 NAS 登录会话，请使用绿联云 App 扫码登录。"
        }
    }
}

private final class NASQRNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Protocol reconstructed from the UGREEN shipped desktop client. No persistent keys,
/// cloud tokens, QR identifiers, or NAS sessions are written or logged here.
actor NASQRBroker {
    private let clientID = UUID().uuidString
    private var generation = UUID()
    private var session: URLSession?
    private var privateKey: SecKey?
    private var qrCode: String?
    private var alias = "Naku Player"
    private var polling = false
    private var consumed = false
    private var origin = "https://api.ugnas.com/api/"

    static func cloudOrigin(_ device: [String:Any]) throws -> String {
        let advertised=device["url"] as? String ?? ""
        let fallback=(device["site_code"] as? String)?.uppercased() == "CN" ? "https://api-zh.ugnas.com":"https://api.ugnas.com"
        guard let u=URLComponents(string:advertised.isEmpty ? fallback:advertised),u.scheme == "https",
              let host=u.host,host.range(of:"^api(-[a-z]{2,4})?\\.ugnas\\.com$",options:.regularExpression) != nil,
              u.user == nil,u.password == nil,u.port == nil,u.query == nil,u.fragment == nil,
              ["","/","/api/"].contains(u.path) else {throw NASQRError.invalidResponse}
        return "https://"+host+"/api/"
    }
    func create(alias: String, serial: String? = nil, device: [String:Any] = [:]) async throws -> [String: Any] {
        cancel()
        origin=try Self.cloudOrigin(device)
        self.alias = alias.isEmpty ? "Naku Player" : String(alias.prefix(128))
        let current = generation
        let key = try makePrivateKey()
        let publicKey = try publicPEM(key)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 25
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let transport = URLSession(configuration: configuration,
                                   delegate: NASQRNoRedirect(), delegateQueue: nil)
        session = transport
        privateKey = key
        var body = identity()
        body["qrType"] = "LOCAL_LOGIN"
        body["ak"] = "UG8FKSDUGREEN001"
        body["public_key"] = publicKey
        if let serial = serial, !serial.isEmpty { body["sn"] = serial }
        let response: [String: Any]
        do {
            response = try await post("user/v3/sa/create/qrCode",
                body: JSONSerialization.data(withJSONObject: body),
                contentType: "application/json", transport: transport)
        } catch {
            guard current == generation else { throw NASQRError.cancelled }
            cancel()
            throw error
        }
        guard current == generation else { throw NASQRError.cancelled }
        guard code(response) == 200 else {
            let failure = serverError(response)
            cancel()
            throw failure
        }
        guard let data = response["data"] as? [String: Any],
              let identifier = data["qrCode"] as? String, !identifier.isEmpty,
              let rawURL = data["url"] as? String,
              let url = URL(string: rawURL), url.scheme == "https", url.host != nil else {
            cancel()
            throw NASQRError.invalidResponse
        }
        qrCode = identifier
        // The observed API supplies no expiry duration. Server code 8058 governs
        // expiry; do not invent a countdown or expose the poll identifier.
        return ["url": rawURL, "expiresIn": NSNull(), "region":device["site_code"] as? String ?? ""]
    }

    func poll() async throws -> NASQRResult {
        guard let identifier = qrCode, let transport = session,
              privateKey != nil, !consumed else { throw NASQRError.cancelled }
        guard !polling else { return .waiting }
        let current = generation
        polling = true
        defer { if current == generation { polling = false } }
        var form = identity()
        form["grant_type"] = "qrcode"
        form["qrcode"] = identifier
        let boundary = "NakuQR-" + UUID().uuidString
        let body = multipart(form, boundary: boundary)
        let response: [String: Any]
        do {
            response = try await post("oauth/token", body: body,
                contentType: "multipart/form-data; boundary=\(boundary)", transport: transport)
        } catch {
            guard current == generation else { throw NASQRError.cancelled }
            throw error
        }
        guard current == generation, !consumed else { throw NASQRError.cancelled }
        switch code(response) {
        case 81520: return .waiting
        case 81308: return .scanned
        case 8058:
            cancel()
            return .expired
        case 200:
            guard let data = response["data"] as? [String: Any],
                  let user = data["user"] as? [String: Any],
                  user["scanType"] as? String == "localScan" else {
                cancel()
                throw NASQRError.unexpectedLoginType
            }
            guard let raw = user["linkParams"] as? String,
                  let encoded = raw.data(using: .utf8),
                  var params = try JSONSerialization.jsonObject(with: encoded) as? [String: Any],
                  let token = params["token"] as? String, !token.isEmpty else {
                cancel()
                throw NASQRError.invalidResponse
            }
            if (params["token_safe"] as? Bool) == true || (params["token_safe"] as? NSNumber)?.intValue == 1 {
                params["token"] = try decrypt(token)
            }
            // Main actor must validate returned NAS identity against the intended
            // device before adopting or persisting this native-only dictionary.
            consumed = true
            qrCode = nil
            privateKey = nil
            transport.invalidateAndCancel()
            session = nil
            return .authorized(params)
        default:
            let failure = serverError(response)
            cancel()
            throw failure
        }
    }

    func cancel() {
        generation = UUID()
        session?.invalidateAndCancel()
        session = nil
        privateKey = nil
        qrCode = nil
        polling = false
        consumed = false
    }

    private func identity() -> [String: String] {
        ["platform": "Mac", "clientType": "Mac", "model": "Mac",
         "osVer": ProcessInfo.processInfo.operatingSystemVersionString,
         "bid": clientID, "alias": alias]
    }

    private func post(_ path: String, body: Data, contentType: String,
                      transport: URLSession) async throws -> [String: Any] {
        guard let url = URL(string: origin + path) else { throw NASQRError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("PC/WEB", forHTTPHeaderField: "UG-Agent")
        request.setValue("zh-CN", forHTTPHeaderField: "Accept-Language")
        let (data, response) = try await transport.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NASQRError.invalidResponse
        }
        return object
    }

    private func code(_ response: [String: Any]) -> Int {
        (response["code"] as? NSNumber)?.intValue ?? -1
    }

    private func serverError(_ response: [String: Any]) -> NASQRError {
        // Never echo server-supplied messages: they can contain session identifiers.
        let number = code(response)
        let message = number == 81604 ? "当前网络或 NAS 远程连接环境不满足要求，请检查后刷新。" : "请刷新二维码重试。"
        return .rejected(number, message)
    }

    private func multipart(_ fields: [String: String], boundary: String) -> Data {
        var data = Data()
        for name in fields.keys.sorted() {
            data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(fields[name]!)\r\n".utf8))
        }
        data.append(Data("--\(boundary)--\r\n".utf8))
        return data
    }

    private func makePrivateKey() throws -> SecKey {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecPrivateKeyAttrs as String: [kSecAttrIsPermanent as String: false]
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attributes as CFDictionary, &error) else {
            throw NASQRError.cryptography
        }
        return key
    }

    private func publicPEM(_ key: SecKey) throws -> String {
        var error: Unmanaged<CFError>?
        guard let publicKey = SecKeyCopyPublicKey(key),
              let bytes = SecKeyCopyExternalRepresentation(publicKey, &error) else {
            throw NASQRError.cryptography
        }
        // Security exports PKCS#1. The shipped client emits SPKI content under an
        // RSA PUBLIC KEY label; reproduce that exact wire representation.
        let algorithm = Data([0x30, 0x0d, 0x06, 0x09, 0x2a, 0x86, 0x48,
                              0x86, 0xf7, 0x0d, 0x01, 0x01, 0x01, 0x05, 0x00])
        var bits = Data([0]); bits.append(bytes as Data)
        var sequence = algorithm; sequence.append(der(tag: 0x03, content: bits))
        let base64 = der(tag: 0x30, content: sequence).base64EncodedString()
        let lines = stride(from: 0, to: base64.count, by: 64).map { offset -> String in
            let start = base64.index(base64.startIndex, offsetBy: offset)
            let end = base64.index(start, offsetBy: min(64, base64.count - offset))
            return String(base64[start..<end])
        }
        return "-----BEGIN RSA PUBLIC KEY-----\n" + lines.joined(separator: "\n") + "\n-----END RSA PUBLIC KEY-----"
    }

    private func der(tag: UInt8, content: Data) -> Data {
        var output = Data([tag])
        if content.count < 128 { output.append(UInt8(content.count)) }
        else {
            var length = content.count
            var bytes: [UInt8] = []
            while length > 0 { bytes.insert(UInt8(length & 255), at: 0); length >>= 8 }
            output.append(0x80 | UInt8(bytes.count)); output.append(contentsOf: bytes)
        }
        output.append(content)
        return output
    }

    private func decrypt(_ ciphertext: String) throws -> String {
        guard let key = privateKey, let bytes = Data(base64Encoded: ciphertext) else {
            throw NASQRError.cryptography
        }
        var error: Unmanaged<CFError>?
        guard let plaintext = SecKeyCreateDecryptedData(key, .rsaEncryptionPKCS1,
                                                       bytes as CFData, &error),
              let token = String(data: plaintext as Data, encoding: .utf8), !token.isEmpty else {
            throw NASQRError.cryptography
        }
        return token
    }
}
