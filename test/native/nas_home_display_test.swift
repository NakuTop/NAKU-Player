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
    func allCookies() async -> [HTTPCookie] {cookies}
    func setCookie(_ cookie: HTTPCookie) async {
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
    static var proof: [String:Any]=[:]
    private static let deferredLock=NSLock()
    private static var deferred: HomeDisplayFixtureProtocol?
    static var onDeferredExchange: (() -> Void)?
    static func failDeferredExchange() {
        let pending=deferredLock.withLock {let pending=deferred;deferred=nil;return pending}
        precondition(pending != nil,"no deferred exchange")
        pending!.client!.urlProtocol(pending!,didFailWithError:URLError(.timedOut))
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
            if Self.mode == "delayed-failure" {
                Self.deferredLock.withLock {Self.deferred=self}
                Self.onDeferredExchange?()
                return
            }
            let expiry=Date().timeIntervalSince1970*1000+299_000
            payload=["authenticated":true,"expiresAt":expiry]
            headers["Set-Cookie"]="__Host-naku-display=fixture-display-credential; Max-Age=300; Path=/; Secure; HttpOnly; SameSite=Strict, __Host-naku-display-context=1; Path=/; Secure; HttpOnly; SameSite=Strict"
            if Self.mode == "redirect" {status=307;headers["Location"]="https://evil.test/stolen"}
            if Self.mode == "wrong-origin" {responseURL=URL(string:"https://evil.test/api/auth/nas/exchange")!}
            if Self.mode == "no-httponly" {headers["Set-Cookie"]=headers["Set-Cookie"]!.replacingOccurrences(of:"; HttpOnly",with:"")}
            if Self.mode == "domain" {headers["Set-Cookie"]! += "; Domain=between-us-home.pages.dev"}
            if Self.mode == "expired" {headers["Set-Cookie"]="__Host-naku-display=expired; Max-Age=0; Path=/; Secure; HttpOnly";payload["expiresAt"]=0}
            if Self.mode == "marker-only" {headers["Set-Cookie"]="__Host-naku-display-context=1; Path=/; Secure; HttpOnly; SameSite=Strict"}
            if Self.mode == "missing-config" {status=503;headers=[:];payload=["error":"nas_display_unconfigured"]}
        } else {
            var data:[String:Any]=[:]
            if path.hasSuffix("/verify/sn") {data=["sn":"fixture-public-routing-hint"]}
            else if path.hasSuffix("/current/user") {data=["username":"fixture-member","uid":42]}
            else if path.hasSuffix("/machine/common") {data=["common":["serial":"fixture-canonical-serial"]]}
            else {fatalError("Unexpected fixture route")}
            payload=["code":200,"data":data]
        }
        let response=HTTPURLResponse(url:responseURL,statusCode:status,httpVersion:nil,headerFields:headers)!
        client!.urlProtocol(self,didReceive:response,cacheStoragePolicy:.notAllowed)
        client!.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:payload))
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
        try await lifecycle(session,store,pem)
    }
}
