import Foundation
import CryptoKit

// Compile the actual method-channel callback without loading Flutter or a
// WebKit data store. The callback still runs on its production MainActor path.
struct FlutterMethodCall {let method: String;let arguments: Any?}
typealias FlutterResult = (Any?) -> Void
let FlutterMethodNotImplemented = NSObject()
struct FlutterError {let code: String;let message: String;let details: Any?}

actor HomeDisplayFixtureGate {
    private var opened=false
    private var waiters=[CheckedContinuation<Void,Never>]()
    func wait() async {
        if opened {return}
        await withCheckedContinuation {waiters.append($0)}
    }
    func open() {
        opened=true
        let pending=waiters;waiters=[]
        for waiter in pending {waiter.resume()}
    }
}

@MainActor final class HomeDisplayFixtureCookieStore: NASHomeDisplayCookieStore {
    var cookies=[HTTPCookie]()
    var deletionGate: HomeDisplayFixtureGate?
    var deletionStarted=HomeDisplayFixtureGate()
    var deleteCount=0
    var rejectWrites=false
    func allCookies() async -> [HTTPCookie] {cookies}
    func setCookie(_ cookie: HTTPCookie) async {
        if rejectWrites {return}
        cookies.removeAll {$0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path}
        cookies.append(cookie)
    }
    func deleteCookie(_ cookie: HTTPCookie) async {
        await deletionStarted.open()
        await deletionGate?.wait()
        deleteCount += 1
        cookies.removeAll {$0.name == cookie.name && $0.domain == cookie.domain && $0.path == cookie.path}
    }
    var hasCredential: Bool {cookies.contains {NASHomeDisplayCookiePolicy.shouldInvalidate($0)}}
    var hasContext: Bool {cookies.contains {$0.name == "__Host-naku-display-context"}}
    var hasOwner: Bool {cookies.contains {$0.name == "sb-owner-auth-token"}}
}

@MainActor final class HomeDisplayFixtureCallback {
    var returned=false
    var value: Any?
    let completed=HomeDisplayFixtureGate()
    func receive(_ result: Any?) {
        returned=true;value=result
        Task {await completed.open()}
    }
}

final class HomeDisplayFixtureProtocol: URLProtocol {
    static var mode="valid",exchangeCount=0
    static var currentReads=0,deviceReads=0
    static var proof: [String:Any]=[:]
    private static let deferredLock=NSLock()
    private static var deferred: HomeDisplayFixtureProtocol?
    private static var deferredProbes=[HomeDisplayFixtureProtocol]()
    static var onDeferredExchange: (() -> Void)?
    static var onDeferredProbe: (() -> Void)?
    static func failDeferredExchange() {
        let pending=deferredLock.withLock {let pending=deferred;deferred=nil;return pending}
        precondition(pending != nil,"no deferred exchange")
        pending!.client!.urlProtocol(pending!,didFailWithError:URLError(.timedOut))
    }
    static func failDeferredProbes() {
        let pending=deferredLock.withLock {let pending=deferredProbes;deferredProbes=[];return pending}
        precondition(!pending.isEmpty,"no deferred local probe")
        for item in pending {item.client!.urlProtocol(item,didFailWithError:URLError(.timedOut))}
    }
    override class func canInit(with request: URLRequest) -> Bool {true}
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {request}
    static func body(_ request: URLRequest) -> Data {
        if let body=request.httpBody {return body}
        guard let stream=request.httpBodyStream else {return Data()}
        stream.open();defer {stream.close()}
        var result=Data(),buffer=[UInt8](repeating:0,count:4096)
        while stream.hasBytesAvailable {let count=stream.read(&buffer,maxLength:buffer.count);if count<=0 {break};result.append(contentsOf:buffer.prefix(count))}
        return result
    }
    override func startLoading() {
        let path=request.url!.path
        var status=200,headers=[String:String](),payload:[String:Any]
        var responseURL=request.url!
        if path == "/api/auth/nas/exchange" {
            precondition(request.url!.absoluteString == "https://between-us-home.pages.dev/api/auth/nas/exchange")
            precondition(request.httpMethod == "POST" && request.value(forHTTPHeaderField:"Content-Type") == "application/json")
            precondition(request.value(forHTTPHeaderField:"Origin") == "https://between-us-home.pages.dev")
            let body=Self.body(request)
            precondition(!String(data:body,encoding:.utf8)!.contains("fixture-private-token"))
            Self.proof=try! JSONSerialization.jsonObject(with:body) as! [String:Any]
            Self.exchangeCount += 1
            if Self.mode == "transport-timeout" || Self.mode == "transport-dns" {
                client!.urlProtocol(self,didFailWithError:URLError(Self.mode == "transport-timeout" ? .timedOut:.cannotFindHost))
                return
            }
            if Self.mode == "delayed-failure" {
                Self.deferredLock.withLock {Self.deferred=self}
                Self.onDeferredExchange?()
                return
            }
            let expiry=Date().timeIntervalSince1970*1000+299_000
            payload=["authenticated":true,"expiresAt":expiry]
            headers["Set-Cookie"]="__Host-naku-display=fixture-display-credential; Max-Age=300; Path=/; Secure; HttpOnly; SameSite=Strict, __Host-naku-display-context=1; Path=/; Secure; HttpOnly; SameSite=Strict"
            if Self.mode.hasPrefix("cookie-format-") {
                // Match NextResponse's real attributes, including Expires' comma.
                let date=DateFormatter();date.locale=Locale(identifier:"en_US_POSIX");date.timeZone=TimeZone(secondsFromGMT:0);date.dateFormat="EEE, dd MMM yyyy HH:mm:ss 'GMT'"
                let expires=Self.mode.contains("expires") ? "; Expires="+date.string(from:Date().addingTimeInterval(300)):""
                let credential="__Host-naku-display=fixture-display-credential; Path=/"+expires+"; Max-Age=300; Secure; HttpOnly; SameSite=strict"
                let context="__Host-naku-display-context=1; Path=/; Secure; HttpOnly; SameSite=strict"
                let fields=Self.mode.contains("reverse") ? [context,credential]:[credential,context]
                headers["Set-Cookie"]=fields.joined(separator:Self.mode.contains("no-space") ? ",":", ")
            }
            if Self.mode == "redirect" {status=307;headers["Location"]="https://evil.test/stolen"}
            if Self.mode == "wrong-origin" {responseURL=URL(string:"https://evil.test/api/auth/nas/exchange")!}
            if Self.mode == "no-httponly" {headers["Set-Cookie"]=headers["Set-Cookie"]!.replacingOccurrences(of:"; HttpOnly",with:"")}
            if Self.mode == "no-cookie" {headers.removeValue(forKey:"Set-Cookie")}
            if Self.mode == "cookie-no-space" {headers["Set-Cookie"]=headers["Set-Cookie"]!.replacingOccurrences(of:"Strict, ",with:"Strict,")}
            if Self.mode == "cookie-duplicate-credential" {headers["Set-Cookie"]! += ",__Host-naku-display=second-credential; Path=/; Max-Age=300; Secure; HttpOnly; SameSite=Strict"}
            if Self.mode == "cookie-duplicate-context" {headers["Set-Cookie"]! += ",__Host-naku-display-context=1; Path=/; Secure; HttpOnly; SameSite=Strict"}
            if Self.mode == "cookie-duplicate-conflicting-context" {headers["Set-Cookie"]! += ",__Host-naku-display-context=2; Path=/; Secure; HttpOnly; SameSite=Strict"}
            if Self.mode == "cookie-marker-invalid" {headers["Set-Cookie"]=headers["Set-Cookie"]!.replacingOccurrences(of:"display-context=1;",with:"display-context=2;")}
            if Self.mode == "cookie-marker-persistent" {headers["Set-Cookie"]! += "; Max-Age=300"}
            if Self.mode == "cookie-expiry-missing" {headers["Set-Cookie"]=headers["Set-Cookie"]!.replacingOccurrences(of:"Max-Age=300; ",with:"")}
            if Self.mode == "domain" {headers["Set-Cookie"]! += "; Domain=between-us-home.pages.dev"}
            if Self.mode == "expired" {headers["Set-Cookie"]="__Host-naku-display=expired; Max-Age=0; Path=/; Secure; HttpOnly";payload["expiresAt"]=0}
            if Self.mode == "marker-only" {headers["Set-Cookie"]="__Host-naku-display-context=1; Path=/; Secure; HttpOnly; SameSite=Strict"}
            if Self.mode == "missing-config" {status=503;headers=[:];payload=["error":"nas_display_unconfigured"]}
            if Self.mode.hasPrefix("http-"),let requested=Int(Self.mode.dropFirst(5)) {
                status=requested;headers=[:];payload=["error":"fixture-private-token-must-not-be-returned"]
            }
            if Self.mode.hasPrefix("diagnostic-") {status=401;headers=[:];payload=["error":"nas_authentication_failed"]}
            if Self.mode == "invalid-payload" {payload=["authenticated":true,"expiresAt":0,"error":"fixture-private-token-must-not-be-returned"]}
            if Self.mode == "unauthorized-payload" {payload=["authenticated":false,"expiresAt":expiry]}
        } else {
            var data:[String:Any]=[:]
            if path.hasSuffix("/verify/sn") {data=["sn":"fixture-public-routing-hint"]}
            else if path.hasSuffix("/current/user") {Self.currentReads += 1;data=["username":"fixture-member","uid":42]}
            else if path.hasSuffix("/machine/common") {Self.deviceReads += 1;data=["common":["serial":"fixture-canonical-serial"]]}
            else {fatalError("Unexpected fixture route")}
            if Self.mode.hasPrefix("diagnostic-") || Self.mode == "http-401" {
                precondition(request.httpMethod == "GET" && request.timeoutInterval <= 4.01,"diagnostics use bounded existing read-only APIs")
                if Self.mode == "diagnostic-delayed" {
                    Self.deferredLock.withLock {Self.deferredProbes.append(self)}
                    Self.onDeferredProbe?()
                    return
                }
                if Self.mode == "diagnostic-deadline" {return}
                if Self.mode == "diagnostic-expired" {payload=["code":401,"data":[:]];respond(status:status,headers:headers,payload:payload,responseURL:responseURL);return}
                if Self.mode == "diagnostic-device-denied" && path.hasSuffix("/machine/common") {payload=["code":403,"data":[:]];respond(status:status,headers:headers,payload:payload,responseURL:responseURL);return}
                if Self.mode == "diagnostic-mismatch" && path.hasSuffix("/machine/common") {data=["common":["serial":"fixture-other-device"]]}
            }
            payload=["code":200,"data":data]
        }
        respond(status:status,headers:headers,payload:payload,responseURL:responseURL)
    }
    private func respond(status: Int,headers: [String:String],payload: [String:Any],responseURL: URL) {
        let response=HTTPURLResponse(url:responseURL,statusCode:status,httpVersion:nil,headerFields:headers)!
        client!.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client!.urlProtocol(self,didLoad:Self.mode == "invalid-payload-body" ? Data("[]".utf8):try! JSONSerialization.data(withJSONObject:payload))
        client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct NASHomeDisplayTests {
    static func expect(_ value: Bool,_ message: String) {if !value {fatalError(message)}}
    static func query(_ proof: [String:Any]) throws -> String {
        let key=proof["responseKey"] as! String,encoded=proof["query"] as! String
        let data=try AES.GCM.open(AES.GCM.SealedBox(combined:Data(base64Encoded:encoded)!),using:SymmetricKey(data:Data(key.utf8)))
        return String(data:data,encoding:.utf8)!
    }
    @MainActor static func adopt(_ session: NASMovieSession,_ pem: String) async throws {
        _ = try await session.adoptQRPayload(["token":"fixture-private-token","public_key":Data(pem.utf8).base64EncodedString(),"uid":42],
            target:URL(string:"https://fixture.cn21.ug.link")!,expectedDeviceHint:"fixture-public-routing-hint",remember:nil)
    }
    @MainActor static func lifecycle(_ session: NASMovieSession,_ store: HomeDisplayFixtureCookieStore,_ pem: String) async throws {
        HomeDisplayFixtureProtocol.mode="valid"
        expect(await session.homeDisplayAuthorize()["authenticated"] as? Bool == true,"fixture authorization installed")
        store.cookies.append(HTTPCookie(properties:[.name:"sb-owner-auth-token",.value:"fixture-owner",.domain:"between-us-home.pages.dev",.path:"/"])!)

        let firstStarted=HomeDisplayFixtureGate(),before=HomeDisplayFixtureProtocol.exchangeCount
        HomeDisplayFixtureProtocol.onDeferredExchange={Task {await firstStarted.open()}}
        HomeDisplayFixtureProtocol.mode="delayed-failure"
        let older=await session.homeDisplayAuthorizationTask()
        await firstStarted.wait()
        let overlapping=await session.homeDisplayAuthorizationTask()
        expect(HomeDisplayFixtureProtocol.exchangeCount == before+1,"overlapping renewals share one exchange")
        HomeDisplayFixtureProtocol.failDeferredExchange()
        expect(await older.value["authenticated"] as? Bool == false,"delayed shared exchange failure is rejected")
        expect(await overlapping.value["authenticated"] as? Bool == false,"overlapping caller receives the same failed flight")
        expect(!store.hasCredential && store.hasContext && store.hasOwner,"shared failure invalidates only the display credential")
        HomeDisplayFixtureProtocol.mode="valid"
        expect(await session.homeDisplayAuthorize()["authenticated"] as? Bool == true,"a fresh renewal succeeds after the failed flight")
        print("PASS overlapping same-generation renewals are single-flight; delayed failure completes before the next success")

        let staleStarted=HomeDisplayFixtureGate()
        HomeDisplayFixtureProtocol.onDeferredExchange={Task {await staleStarted.open()}}
        HomeDisplayFixtureProtocol.mode="delayed-failure"
        let stale=await session.homeDisplayAuthorizationTask()
        await staleStarted.wait()
        await session.logoutAndInvalidateDisplay()
        HomeDisplayFixtureProtocol.mode="valid"
        try await adopt(session,pem)
        expect(await session.homeDisplayAuthorize()["authenticated"] as? Bool == true,"new NAS generation installs a fresh credential")
        let deletedBeforeStaleFailure=store.deleteCount
        HomeDisplayFixtureProtocol.failDeferredExchange()
        expect(await stale.value["authenticated"] as? Bool == false,"old NAS generation failure is rejected")
        expect(store.hasCredential && store.deleteCount == deletedBeforeStaleFailure,"delayed old-generation failure cannot clear the latest success")
        print("PASS delayed old-generation failure cannot invalidate a newer successfully installed credential")

        let bridge=NakuNASMovies(session:session),logoutCallback=HomeDisplayFixtureCallback()
        store.deletionGate=HomeDisplayFixtureGate();store.deletionStarted=HomeDisplayFixtureGate()
        bridge.handle(FlutterMethodCall(method:"logout",arguments:nil)) {logoutCallback.receive($0)}
        await store.deletionStarted.wait()
        expect(!logoutCallback.returned && store.hasCredential,"logout callback waits while credential deletion is blocked")
        await store.deletionGate!.open()
        await logoutCallback.completed.wait()
        expect(logoutCallback.returned && logoutCallback.value == nil && !store.hasCredential,"logout callback returns only after credential invalidation")
        expect(store.hasContext && store.hasOwner,"public logout retains context and owner cookies")

        store.deletionGate=nil
        try await adopt(session,pem)
        expect(await session.homeDisplayAuthorize()["authenticated"] as? Bool == true,"fixture reauthorization succeeds")
        let forgetCallback=HomeDisplayFixtureCallback()
        store.deletionGate=HomeDisplayFixtureGate();store.deletionStarted=HomeDisplayFixtureGate()
        bridge.handle(FlutterMethodCall(method:"forget",arguments:nil)) {forgetCallback.receive($0)}
        await store.deletionStarted.wait()
        expect(!forgetCallback.returned,"forget callback waits while credential deletion is blocked")
        // A session switch while forget is suspended must prevent saved-entry
        // deletion. This path throws before either real Keychain store is used.
        let switched=await session.logout()
        await store.deletionGate!.open()
        await forgetCallback.completed.wait()
        await switched.value
        expect((forgetCallback.value as? FlutterError)?.code == "nas","stale forget is rejected before saved credentials can be deleted")
        expect(!store.hasCredential && store.hasContext && store.hasOwner,"forget completion retains context and owner cookies")
        print("PASS actual logout/forget callbacks await invalidation; a generation change prevents stale saved-credential deletion")
    }
    @MainActor static func cookieFormats(_ session: NASMovieSession,_ store: HomeDisplayFixtureCookieStore) async {
        let modes=["cookie-format-forward","cookie-format-reverse","cookie-format-forward-no-space","cookie-format-reverse-no-space",
            "cookie-format-forward-expires","cookie-format-reverse-expires","cookie-format-forward-expires-no-space","cookie-format-reverse-expires-no-space","cookie-no-space"]
        for mode in modes {
            HomeDisplayFixtureProtocol.mode=mode
            let beforeCurrent=HomeDisplayFixtureProtocol.currentReads,beforeDevice=HomeDisplayFixtureProtocol.deviceReads
            let value=await session.homeDisplayAuthorize()
            expect(value["authenticated"] as? Bool == true,"legitimate combined Set-Cookie format is accepted: "+mode)
            expect(HomeDisplayFixtureProtocol.currentReads == beforeCurrent && HomeDisplayFixtureProtocol.deviceReads == beforeDevice,"cookie compatibility adds no NAS reads")
            expect(store.hasCredential && store.hasContext,"both independently scoped cookies installed: "+mode)
            let context=store.cookies.first {$0.name == "__Host-naku-display-context"}
            expect(context?.isSessionOnly == true && context?.isHTTPOnly == true && context?.isSecure == true,"context remains session-only Secure HttpOnly: "+mode)
        }
        HomeDisplayFixtureProtocol.mode="valid"
        print("PASS comma/no-space, either cookie order and Expires date commas remain compatible without weakening cookie policy")
    }
    @MainActor static func diagnostics(_ session: NASMovieSession,_ store: HomeDisplayFixtureCookieStore) async throws {
        let cases:[(String,String,String,Int?,Int?)]=[
            ("http-401","nas_authentication_failed","exchange_http",401,nil),
            ("http-403","backend_access_rejected","exchange_http",403,nil),
            ("http-429","backend_rate_limited","exchange_http",429,nil),
            ("http-500","backend_http_error","exchange_http",500,nil),
            ("missing-config","backend_unconfigured","exchange_http",503,nil),
            ("transport-timeout","backend_timeout","exchange_transport",nil,URLError.Code.timedOut.rawValue),
            ("transport-dns","backend_network_error","exchange_transport",nil,URLError.Code.cannotFindHost.rawValue),
            ("wrong-origin","authorization_response_invalid","response_origin_or_size",nil,nil),
            ("no-cookie","authorization_response_invalid","response_cookie_header",nil,nil),
            ("domain","authorization_response_invalid","response_cookie_header",nil,nil),
            ("no-httponly","authorization_response_invalid","response_cookie_scope",nil,nil),
            ("marker-only","authorization_response_invalid","response_cookie_parse",nil,nil),
            ("cookie-duplicate-credential","authorization_response_invalid","response_cookie_parse",nil,nil),
            ("cookie-duplicate-context","authorization_response_invalid","response_cookie_parse",nil,nil),
            ("cookie-duplicate-conflicting-context","authorization_response_invalid","response_cookie_parse",nil,nil),
            ("cookie-marker-invalid","authorization_response_invalid","response_cookie_marker",nil,nil),
            ("cookie-marker-persistent","authorization_response_invalid","response_cookie_persistence",nil,nil),
            ("cookie-expiry-missing","authorization_response_invalid","response_cookie_expiry",nil,nil),
            ("invalid-payload-body","authorization_response_invalid","response_payload_body",nil,nil),
            ("unauthorized-payload","authorization_response_invalid","response_payload_authorized",nil,nil),
            ("invalid-payload","authorization_response_invalid","response_payload_expiry",nil,nil),
        ]
        for (mode,reason,stage,status,network) in cases {
            HomeDisplayFixtureProtocol.mode=mode
            let beforeCurrent=HomeDisplayFixtureProtocol.currentReads,beforeDevice=HomeDisplayFixtureProtocol.deviceReads
            let value=await session.homeDisplayAuthorize()
            expect(value["authenticated"] as? Bool == false,"failed exchange must stay unauthorized: "+mode)
            expect(value["reason"] as? String == reason && value["stage"] as? String == stage,"exact safe diagnostic classification: "+mode)
            expect(value["httpStatus"] as? Int == status && value["networkCode"] as? Int == network,"only applicable numeric diagnostic codes: "+mode)
            expect(HomeDisplayFixtureProtocol.currentReads-beforeCurrent == (status == 401 ? 1:0) && HomeDisplayFixtureProtocol.deviceReads-beforeDevice == (status == 401 ? 1:0),"only backend 401 triggers one read per NAS endpoint")
            expect(Set(value.keys).isSubset(of:Set(["authenticated","reason","stage","httpStatus","networkCode","nasSessionVerified","nasDeviceVerified","nasSessionCheck","nasDeviceCheck"])),"diagnostic key allowlist")
            let encoded=String(data:try JSONSerialization.data(withJSONObject:value),encoding:.utf8)!
            expect(!encoded.contains("fixture-private-token") && !encoded.contains("fixture-member") && !encoded.contains("fixture-canonical-serial") && !encoded.contains("responseKey") && !encoded.contains("http://") && !encoded.contains("https://"),"no credential, account, serial, URL or backend message in diagnostics")
        }
        HomeDisplayFixtureProtocol.mode="valid"
        store.cookies.removeAll {NASHomeDisplayCookiePolicy.shouldInvalidate($0)}
        store.rejectWrites=true
        let rejected=await session.homeDisplayAuthorize()
        expect(rejected["reason"] as? String == "authorization_cookie_install_failed" && rejected["stage"] as? String == "cookie_install","cookie write failure has a separate safe stage")
        expect(!store.hasCredential,"failed installation leaves no display credential")
        store.rejectWrites=false
        let beforeCurrent=HomeDisplayFixtureProtocol.currentReads,beforeDevice=HomeDisplayFixtureProtocol.deviceReads
        expect(await session.homeDisplayAuthorize()["authenticated"] as? Bool == true,"normal authorization recovers after classified failures")
        expect(HomeDisplayFixtureProtocol.currentReads == beforeCurrent && HomeDisplayFixtureProtocol.deviceReads == beforeDevice,"successful exchange has no extra NAS requests")
        print("PASS safe HTTP/network/response/cookie-install stage diagnostics preserve fail-closed authorization without exposing proof or response details")
    }
    @MainActor static func probeDiagnostics(_ session: NASMovieSession,_ store: HomeDisplayFixtureCookieStore,_ pem: String) async throws {
        let cases:[(String,Bool,Bool,String,String)]=[
            ("http-401",true,true,"verified","verified"),
            ("diagnostic-expired",false,false,"authentication_rejected","authentication_rejected"),
            ("diagnostic-device-denied",true,false,"verified","authentication_rejected"),
            ("diagnostic-mismatch",true,false,"verified","identity_mismatch"),
            ("diagnostic-deadline",false,false,"timeout","timeout"),
        ]
        for (mode,validSession,validDevice,sessionCheck,deviceCheck) in cases {
            HomeDisplayFixtureProtocol.mode=mode
            let beforeCurrent=HomeDisplayFixtureProtocol.currentReads,beforeDevice=HomeDisplayFixtureProtocol.deviceReads,began=Date()
            let value=await session.homeDisplayAuthorize()
            expect(value["authenticated"] as? Bool == false && value["httpStatus"] as? Int == 401,"local probe never grants website access")
            expect(value["nasSessionVerified"] as? Bool == validSession && value["nasDeviceVerified"] as? Bool == validDevice,"local NAS evidence booleans: "+mode)
            expect(value["nasSessionCheck"] as? String == sessionCheck && value["nasDeviceCheck"] as? String == deviceCheck,"local fixed classifications: "+mode)
            expect(HomeDisplayFixtureProtocol.currentReads == beforeCurrent+1 && HomeDisplayFixtureProtocol.deviceReads == beforeDevice+1,"exactly two GETs and no retry: "+mode)
            expect(!(await session.currentSession()).isEmpty,"diagnostic NAS rejection does not clear the held session")
            if mode == "diagnostic-deadline" {expect(Date().timeIntervalSince(began) < 6,"parallel diagnostic reads have a four-second deadline")}
        }
        HomeDisplayFixtureProtocol.mode="valid"
        expect(await session.homeDisplayAuthorize()["authenticated"] as? Bool == true,"recovery before old-generation probe fixture")
        let probeStarted=HomeDisplayFixtureGate()
        HomeDisplayFixtureProtocol.onDeferredProbe={Task {await probeStarted.open()}}
        HomeDisplayFixtureProtocol.mode="diagnostic-delayed"
        let stale=await session.homeDisplayAuthorizationTask()
        await probeStarted.wait()
        await session.logoutAndInvalidateDisplay()
        HomeDisplayFixtureProtocol.mode="valid"
        try await adopt(session,pem)
        expect(await session.homeDisplayAuthorize()["authenticated"] as? Bool == true,"a new generation authorizes during the old diagnostic read")
        let deleted=store.deleteCount
        HomeDisplayFixtureProtocol.failDeferredProbes()
        let retired=await stale.value
        expect(retired["authenticated"] as? Bool == false && retired["reason"] as? String == "nas_session_expired","retired probe cannot report current session evidence")
        let currentSession=await session.currentSession()
        expect(store.hasCredential && store.deleteCount == deleted && !currentSession.isEmpty,"late probe must not clear the new session or cookie")
        print("PASS backend-401-only two bounded NAS GETs distinguish local session/device failures without restoring credentials or mutating a new generation")
    }
    @MainActor static func main() async throws {
        func cookie(_ name: String,_ domain: String) -> HTTPCookie {
            HTTPCookie(properties:[.name:name,.value:"fixture",.domain:domain,.path:"/",.secure:"TRUE"])!
        }
        let website="between-us-home.pages.dev"
        expect(NASHomeDisplayCookiePolicy.shouldInvalidate(cookie("__Host-naku-display",website)),"display credential is invalidated")
        expect(NASHomeDisplayCookiePolicy.shouldInvalidate(cookie("__Host-naku-display","."+website)),"WebKit dotted-domain display credential is invalidated")
        for name in ["__Host-naku-display-context","sb-owner-auth-token","sb-owner-auth-token.0","__Host-naku-display-other"] {
            expect(!NASHomeDisplayCookiePolicy.shouldInvalidate(cookie(name,website)),"context, owner and other cookies must remain: "+name)
        }
        for domain in ["elsewhere.test","child."+website,website+".evil.test"] {
            expect(!NASHomeDisplayCookiePolicy.shouldInvalidate(cookie("__Host-naku-display",domain)),"other hosts must remain: "+domain)
        }
        print("PASS credential-only invalidation preserves context, owner cookies and other hosts")
        let configuration=URLSessionConfiguration.ephemeral;configuration.protocolClasses=[HomeDisplayFixtureProtocol.self]
        let transport=URLSession(configuration:configuration),store=HomeDisplayFixtureCookieStore()
        let session=NASMovieSession(transport:transport,homeDisplayCookies:NASHomeDisplayCookies(store:store))
        do {_ = try await session.exchangeHomeDisplay();fatalError("unauthenticated NAS session accepted")}
        catch NASMovieError.expired {}
        expect(HomeDisplayFixtureProtocol.exchangeCount == 0,"logged out exchange must not send a request")
        let pem=try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
        try await adopt(session,pem)
        let authorized=try await session.exchangeHomeDisplay()
        expect(authorized.cookie.name == "__Host-naku-display" && authorized.cookie.isHTTPOnly && authorized.cookie.isSecure,"only secure HttpOnly display cookie accepted")
        expect(authorized.cookie.domain == "between-us-home.pages.dev" && authorized.cookie.path == "/","cookie is fixed to website host and root")
        expect(authorized.contextCookie.isSessionOnly && authorized.contextCookie.isHTTPOnly,"context marker survives credential expiry for this WebKit session")
        let proof=HomeDisplayFixtureProtocol.proof
        expect(Set(proof.keys) == Set(["version","clientId","currentUser","machine"]),"no origin or account assertions in proof")
        expect(try query(proof["currentUser"] as! [String:Any]) == "token=fixture-private-token","token stays in UGOS encrypted query")
        expect(try query(proof["machine"] as! [String:Any]) == "basic=1&token=fixture-private-token","canonical hardware request includes basic parameter")
        print("PASS fixed HTTPS native exchange, encrypted proof, no token in transport JSON and strict cookie validation")
        for mode in ["redirect","wrong-origin","no-httponly","domain","expired","marker-only","missing-config"] {
            HomeDisplayFixtureProtocol.mode=mode
            do {_ = try await session.exchangeHomeDisplay();fatalError("unsafe response accepted: "+mode)} catch {}
        }
        await session.logout()
        do {_ = try await session.exchangeHomeDisplay();fatalError("logout retained authorization")}
        catch NASMovieError.expired {}
        print("PASS redirects, wrong host, unsafe cookie, expiry, marker-only, missing configuration and NAS logout rejection")
        HomeDisplayFixtureProtocol.mode="valid"
        try await adopt(session,pem)
        await cookieFormats(session,store)
        try await diagnostics(session,store)
        try await probeDiagnostics(session,store,pem)
        try await lifecycle(session,store,pem)
    }
}
