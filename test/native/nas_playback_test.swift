import Foundation
import Security

final class PlaybackFixtureProtocol: URLProtocol {
    static let mutex=NSLock()
    static var closed=[String](),plays=[[String:String]](),infoRequests=0
    override class func canInit(with request: URLRequest) -> Bool {true}
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {request}
    override func startLoading() {
        let path=request.url!.path
        var data:[String:Any]=[:]
        if path.hasSuffix("/transcode/ws") {client!.urlProtocol(self,didFailWithError:URLError(.unsupportedURL));return}
        if path.hasSuffix("/verify/sn") {data=["sn":"0123456789abcdef0123456789abcdef"]}
        else if path.hasSuffix("/machine/common") {data=["common":["serial":"playback-fixture-serial"]]}
        else if path.hasSuffix("/current/user") {data=["username":"fixture-user","uid":42]}
        else if path.hasSuffix("/priority_link") {data=["ipv_4":["192.168.1.10"],"http_port":9999,"https_port":9443]}
        else if path.hasSuffix("/web/info") {
            Self.mutex.lock();Self.infoRequests += 1;Self.mutex.unlock()
            data=["resolution":["name":"4K"],"duration":6509696,"width":3840,"height":2160,
                  "transcodeable":[["name":"4K","resolution":"3840x2160"],["name":"480P","resolution":"720x400"]],
                  "audios":[["id":4354,"title":"中文","raw_language":"chi","isDefault":1]],
                  "subtitles":[["id":6145,"title":"中文字幕","raw_language":"chi","isDefault":1,"is_text":1]],
                  "redir_link":"https://nas.invalid/play?video_name=fixture_video&token=fixture-token"]
        } else if path.hasSuffix("/web/play") {
            let query=Dictionary(uniqueKeysWithValues:URLComponents(url:request.url!,resolvingAgainstBaseURL:false)!.queryItems!.map{($0.name,$0.value ?? "")})
            Self.mutex.lock();Self.plays.append(query);Self.mutex.unlock();data=["bitrate_bps":3768000]
        } else if path.hasSuffix("/web/close") {
            var bytes=request.httpBody ?? Data()
            if bytes.isEmpty,let stream=request.httpBodyStream {
                stream.open();defer {stream.close()};var buffer=[UInt8](repeating:0,count:1024)
                while stream.hasBytesAvailable {let count=stream.read(&buffer,maxLength:buffer.count);if count<=0 {break};bytes.append(contentsOf:buffer.prefix(count))}
            }
            let body=try! JSONSerialization.jsonObject(with:bytes) as! [String:Any]
            Self.mutex.lock();Self.closed.append(body["task_id"] as! String);Self.mutex.unlock()
        } else {fatalError("Unexpected fixture route")}
        let body=try! JSONSerialization.data(withJSONObject:["code":200,"data":data])
        client!.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client!.urlProtocol(self,didLoad:body);client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
final class AutoRouteProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {true}
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {request}
    override func startLoading() {
        // No authorization material may be sent during endpoint discovery.
        precondition(request.value(forHTTPHeaderField:"X-Ugreen-Token") == nil)
        precondition(request.url!.query == nil)
        let hint=request.url!.host == "192.168.1.99" ? "different-device":"fixture-device"
        let bytes=try! JSONSerialization.data(withJSONObject:["code":200,"data":["sn":hint]])
        client!.urlProtocol(self,didReceive:HTTPURLResponse(url:request.url!,statusCode:200,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
        client!.urlProtocol(self,didLoad:bytes);client!.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@main struct NASPlaybackTests {
    static func expect(_ value: Bool,_ name: String) {if !value {fatalError(name)}}
    static func main() async throws {
        let routeConfig=URLSessionConfiguration.ephemeral
        routeConfig.protocolClasses=[AutoRouteProtocol.self]
        let routeTransport=URLSession(configuration:routeConfig)
        let local=await NASMovieSession.selectAutoRoute(lan:["http://192.168.1.10:9999"],remote:["https://fixture.cn21.ug.link"],hint:"fixture-device",transport:routeTransport)
        expect(local == "http://192.168.1.10:9999","LAN preferred while both paths are online")
        let remote=await NASMovieSession.selectAutoRoute(lan:["http://192.168.1.99:9999"],remote:["https://fixture.cn21.ug.link"],hint:"fixture-device",transport:routeTransport)
        expect(remote == "https://fixture.cn21.ug.link","mismatched LAN cannot receive credentials, remote fallback works")
        let invalid=await NASMovieSession.selectAutoRoute(lan:["http://8.8.8.8"],remote:["http://fixture.cn21.ug.link"],hint:"fixture-device",transport:routeTransport)
        expect(invalid == nil,"reject public IP scans and HTTP remote downgrade")
        print("PASS auto route LAN preference, relay fallback, device identity and credential-free probes")

        let code=try NASMovieSession.pairingCode("")
        expect(code.count == 10,"secure pairing code length")
        let formatted=String(code.prefix(5))+"-"+String(code.suffix(5))
        expect(try NASMovieSession.pairingCode(formatted.lowercased()) == code,"pairing code case and separator normalization")
        do {_ = try NASMovieSession.pairingCode("invalid");fatalError("invalid pairing code accepted")}catch NASMovieError.configuration {}
        do {_ = try NASMovieSession.playbackProfileData(["transcodeable":[["name":"invalid","resolution":"../escape"]]]);fatalError("bad profile accepted")}catch NASMovieError.response {}
        do {_ = try NASMovieSession.playbackProfileData(["transcodeable":[["name":"480P","resolution":"720x400"],["name":"duplicate","resolution":"720x400"]]]);fatalError("duplicate accepted")}catch NASMovieError.response {}
        let tracks=NASMovieSession.playbackTrackData([["id":"4354","title":"Chinese","isDefault":1],["id":4354]],subtitles:false)
        expect(tracks.count==1 && tracks[0]["id"] as? Int==4354,"stable actual track ID")
        expect(NASMovieSession.isPrivateIPv4("192.168.1.10"),"RFC1918 accepted")
        expect(!NASMovieSession.isPrivateIPv4("192.168.1.999") && !NASMovieSession.isPrivateIPv4("127.0.0.1") && !NASMovieSession.isPrivateIPv4("169.254.1.1") && !NASMovieSession.isPrivateIPv4("8.8.8.8") && !NASMovieSession.isPrivateIPv4("192.168.01.1"),"non-private or ambiguous address rejected")
        expect(NASMovieSession.connectionCandidates(["ipv_4":["192.168.1.10","8.8.8.8"],"http_port":9999,"https_port":9443]) == ["https://192.168.1.10:9443","http://192.168.1.10:9999"],"only device advertised private candidates")
        expect(NASMovieSession.connectionCandidates(["network_info":[["ip":"192.168.1.10"]]]).isEmpty,"do not guess ports")
        print("PASS profile validation, original track IDs and strict LAN candidates")
        let key=SecKeyCreateRandomKey([kSecAttrKeyType as String:kSecAttrKeyTypeRSA,kSecAttrKeySizeInBits as String:2048] as CFDictionary,nil)!
        let publicKey=SecKeyCopyPublicKey(key)!,bytes=SecKeyCopyExternalRepresentation(publicKey,nil)! as Data
        let pem="-----BEGIN RSA PUBLIC KEY-----\n"+bytes.base64EncodedString()+"\n-----END RSA PUBLIC KEY-----"
        let cfg=URLSessionConfiguration.ephemeral;cfg.protocolClasses=[PlaybackFixtureProtocol.self]
        let transport=URLSession(configuration:cfg),client=NASMovieSession(transport:transport)
        let emptySession=await client.currentSession()
        expect(emptySession.isEmpty,"no active session before login")
        let identity=try await client.adoptQRPayload(["token":"fixture-token","public_key":Data(pem.utf8).base64EncodedString(),"uid":42],target:URL(string:"https://nas.invalid")!,expectedDeviceHint:"0123456789abcdef0123456789abcdef",remember:nil)
        let ns=identity["namespace"] as! String
        let active=await client.currentSession()
        expect(active["namespace"] as? String == ns && active["username"] as? String == "fixture-user","memory-only QR session available without saved credentials")
        expect(active["token"] == nil && active["password"] == nil,"session metadata never exports credentials")
        let connection=try await client.connectionInfo(expected:ns)
        expect(connection["lanCandidates"] as? [String] == ["https://192.168.1.10:9443","http://192.168.1.10:9999"],"authenticated LAN discovery")
        do {_ = try await client.restoreAt(address:"http://8.8.8.8:9999",expected:ns,remember:true);fatalError("public HTTP restore accepted")}catch NASMovieError.configuration {}
        let options=try await client.playbackOptions(expected:ns,id:10,library:2,path:"/media/test.mkv")
        expect(options["durationMs"] as? Int==6509696,"NAS duration is milliseconds")
        expect((options["profiles"] as! [[String:Any]]).count==2,"only returned profiles")
        expect((options["subtitles"] as! [[String:Any]])[0]["id"] as? Int == -1,"off subtitle option")
        expect(PlaybackFixtureProtocol.closed.count==1,"options cleans info task")
        print("PASS options metadata, millis and transient task cleanup")
        let before=PlaybackFixtureProtocol.infoRequests
        do {_ = try await client.playbackOptions(expected:"foreign-account",id:10,library:2,path:"/media/test.mkv");fatalError("foreign account accepted")}catch NASMovieError.configuration {}
        expect(PlaybackFixtureProtocol.infoRequests==before,"wrong account cannot request media")
        do {_ = try await client.startPlayback(expected:ns,id:10,library:2,path:"/media/test.mkv",resolution:"fake-tier",audio:nil,subtitle:nil);fatalError("fake tier accepted")}catch NASMovieError.configuration {}
        expect(PlaybackFixtureProtocol.plays.isEmpty,"unknown profile never starts transcode")
        expect(PlaybackFixtureProtocol.closed.count==2,"failed selection closes own task")
        print("PASS account boundary and unsupported tier cleanup")
        let first=try await client.startPlayback(expected:ns,id:10,library:2,path:"/media/test.mkv",resolution:nil,audio:4354,subtitle:6145)
        let query=PlaybackFixtureProtocol.plays.last!
        expect(query["audio_index"]=="4354" && query["subtitle_index"]=="6145","NAS IDs, not menu offsets")
        expect(query["m3u8_file"]=="fixture_video_720x400.m3u8","default is actual lowest profile")
        expect(query["prefer_h265"]=="false","compatible H264")
        let second=try await client.startPlayback(expected:ns,id:10,library:2,path:"/media/test.mkv",resolution:"3840x2160",audio:nil,subtitle:-1)
        let secondID=second["taskId"] as! String,count=PlaybackFixtureProtocol.closed.count
        await client.closePlayback(task:first["taskId"] as! String,expected:ns)
        expect(PlaybackFixtureProtocol.closed.count==count,"stale close cannot close replacement")
        await client.closePlayback(task:secondID,expected:ns)
        expect(PlaybackFixtureProtocol.closed.last==secondID,"close current task")
        print("PASS HLS selection, actual IDs, stale-close isolation and stop cleanup")
        await client.logout()
        let loggedOut=await client.currentSession()
        expect(loggedOut.isEmpty,"explicit logout clears process session")
        transport.invalidateAndCancel()
    }
}
