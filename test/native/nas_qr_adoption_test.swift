import Foundation
import Security

final class QRFixtureProtocol: URLProtocol {
    static var current: [String:Any] = ["username":"canonical-user","uid":1000]
    static var serial="test-nas-serial"
    static var deviceHint="0123456789abcdef0123456789abcdef"
    static var requests=0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.requests += 1
        let data: [String:Any]
        if request.url!.path.hasSuffix("/verify/sn") { data=["sn":Self.deviceHint] }
        else if request.url!.path.hasSuffix("/machine/common") { data=["common":["serial":Self.serial]] }
        else if request.url!.path.hasSuffix("/current/user") { data=Self.current }
        else { fatalError("Unexpected fixture route") }
        let body=try! JSONSerialization.data(withJSONObject:["code":200,"data":data])
        client!.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client!.urlProtocol(self,didLoad:body);client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct QRAdoptionTests {
    static func expect(_ value: Bool, _ name: String) { if !value {fatalError(name)} }
    static func main() async throws {
        expect(try NASQRBroker.cloudOrigin(["site_code":"CN","url":"https://api-zh.ugnas.com"]) == "https://api-zh.ugnas.com/api/","NAS CN node must override client geolocation")
        expect(try NASQRBroker.cloudOrigin(["site_code":"CN"]) == "https://api-zh.ugnas.com/api/","CN fallback is region-specific")
        for url in ["http://api-zh.ugnas.com","https://api-zh.ugnas.com.evil.example","https://user@api-zh.ugnas.com","https://api-zh.ugnas.com?token=x"] {
            do {_ = try NASQRBroker.cloudOrigin(["url":url]);fatalError("untrusted cloud endpoint accepted")} catch NASQRError.invalidResponse {}
        }
        print("PASS NAS-region QR endpoint selection and untrusted endpoint rejection")
        let attributes:[String:Any]=[kSecAttrKeyType as String:kSecAttrKeyTypeRSA,kSecAttrKeySizeInBits as String:2048]
        let key=SecKeyCreateRandomKey(attributes as CFDictionary,nil)!
        let publicKey=SecKeyCopyPublicKey(key)!
        let bytes=SecKeyCopyExternalRepresentation(publicKey,nil)! as Data
        let pem="-----BEGIN RSA PUBLIC KEY-----\n"+bytes.base64EncodedString()+"\n-----END RSA PUBLIC KEY-----"
        let cfg=URLSessionConfiguration.ephemeral;cfg.protocolClasses=[QRFixtureProtocol.self]
        let transport=URLSession(configuration:cfg)
        let client=NASMovieSession(transport:transport)
        let target=URL(string:"https://nas.fixture")!
        let serial=QRFixtureProtocol.serial
        let p:[String:Any]=["token":"fixture-token","public_key":Data(pem.utf8).base64EncodedString(),"uid":"1000"]
        let info=try await client.adoptQRPayload(p,target:target,expectedDeviceHint:QRFixtureProtocol.deviceHint,remember:nil)
        expect(info["username"] as? String == "canonical-user","Account must come from NAS")
        expect(info["namespace"] as? String == NASMovieSession.namespace(serial:serial,username:"canonical-user"),"Stable account namespace")
        print("PASS opaque routing hint differs from canonical serial; missing cloud hints + string UID uses NAS identity")
        var complete=p;complete["sn"]=serial;complete["username"]="canonical-user"
        let matched=try await client.adoptQRPayload(complete,target:target,expectedDeviceHint:QRFixtureProtocol.deviceHint,remember:nil)
        expect(matched["namespace"] as? String == info["namespace"] as? String,"routing hash must never replace canonical account identity")
        print("PASS explicit canonical QR serial matches authenticated device despite different public hint")
        var raw=p;raw["public_key"]=pem
        _ = try await client.adoptQRPayload(raw,target:target,expectedDeviceHint:QRFixtureProtocol.deviceHint,remember:nil)
        print("PASS raw PEM accepted")
        var foreign=p;foreign["sn"]="foreign-nas"
        do { _ = try await client.adoptQRPayload(foreign,target:target,expectedDeviceHint:QRFixtureProtocol.deviceHint,remember:nil);fatalError("foreign NAS accepted") }
        catch NASQRError.deviceMismatch {}
        print("PASS conflicting cloud device rejected")
        var bound=p;bound["sn"]=serial
        QRFixtureProtocol.serial="replaced-nas"
        do {_ = try await client.adoptQRPayload(bound,target:target,expectedDeviceHint:QRFixtureProtocol.deviceHint,remember:nil);fatalError("replaced target accepted")}
        catch NASQRError.deviceMismatch {}
        QRFixtureProtocol.serial=serial
        print("PASS changed target device rejected")
        var wrongUser=p;wrongUser["username"]="another-user"
        do {_ = try await client.adoptQRPayload(wrongUser,target:target,expectedDeviceHint:QRFixtureProtocol.deviceHint,remember:nil);fatalError("wrong username accepted")}
        catch NASQRError.accountMismatch {}
        var wrongUID=p;wrongUID["uid"]="1001"
        do {_ = try await client.adoptQRPayload(wrongUID,target:target,expectedDeviceHint:QRFixtureProtocol.deviceHint,remember:nil);fatalError("wrong UID accepted")}
        catch NASQRError.accountMismatch {}
        print("PASS conflicting account hints rejected")
        var missing=p;missing.removeValue(forKey:"public_key")
        do {_ = try await client.adoptQRPayload(missing,target:target,expectedDeviceHint:QRFixtureProtocol.deviceHint,remember:nil);fatalError("missing key accepted")}
        catch NASQRError.invalidResponse {}
        print("PASS missing session material rejected")
        await client.logout();transport.invalidateAndCancel()
    }
}
