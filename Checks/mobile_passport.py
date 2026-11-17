"""Exercise production mobile-passport requests and login state using synthetic replies only.

The Linux adapter supplies OpenSSL at the CryptoKit/SecKey leaf; all encoding, PEM
unwrapping, request fields, response decoding, owner binding and flow code is production.
Use --anonymous only for public-key + fresh, unscanned QR connectivity (no credentials).
"""
from pathlib import Path
import hashlib, json, re, subprocess, sys, tempfile
from urllib.parse import parse_qsl, quote, unquote, urlsplit

native = Path(__file__).resolve().parents[1]
source = native / "Sources/PiliNative/Account"

fixture = r'''
import Foundation
import FoundationNetworking
protocol ObservableObject: AnyObject {}
func openssl(_ arguments:[String], input:Data?=nil) throws -> Data {
  let p=Process();p.executableURL=URL(fileURLWithPath:"/usr/bin/openssl");p.arguments=arguments
  let output=Pipe(),errors=Pipe();p.standardOutput=output;p.standardError=errors
  let pipe=Pipe();if input != nil{p.standardInput=pipe}
  try p.run()
  if let input {try pipe.fileHandleForWriting.write(contentsOf:input);try pipe.fileHandleForWriting.close()}
  let bytes=output.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
  guard p.terminationStatus==0 else{throw ServiceError("fixture OpenSSL failure")};return bytes
}
enum Insecure {enum MD5 {static func hash(data:Data)->[UInt8]{Array(try! openssl(["dgst","-md5","-binary"],input:data))}}}
enum MobileRSA {
  static func encrypt(_ bytes:Data,publicKey:Data)throws->Data{
    let root=URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:false)
    defer{try? FileManager.default.removeItem(at:root)}
    let key=root.appendingPathComponent("key.der"),plain=root.appendingPathComponent("input")
    try publicKey.write(to:key);try bytes.write(to:plain)
    return try openssl(["pkeyutl","-encrypt","-pubin","-keyform","DER","-inkey",key.path,"-in",plain.path,"-pkeyopt","rsa_padding_mode:pkcs1"])
  }
}
enum MobileDeviceID {static func guest()->String{"fixture-buvid"};static func valid(_ value:String)->Bool{!value.isEmpty}}
enum MobilePassportNetwork {
  static func send(_ request:URLRequest)async throws->Data{
    let config=URLSessionConfiguration.ephemeral;config.httpCookieStorage=nil;config.urlCredentialStorage=nil;config.httpShouldSetCookies=false
    let session=URLSession(configuration:config);defer{session.finishTasksAndInvalidate()}
    let (bytes,response)=try await session.data(for:request)
    guard (response as? HTTPURLResponse)?.statusCode==200 else{throw ServiceError("anonymous HTTP error")};return bytes
  }
}
enum WebLoginIdentity {
  static func verify(_ cookies:[String:String])async throws->(cookies:[String:String],name:String){
    try await Task.sleep(nanoseconds:70_000_000)
    guard cookies["SESSDATA"]=="fixture-cookie-100" else{throw ServiceError("synthetic invalid web identity")}
    var result=cookies;result["DedeUserID"]="100";return(result,"fixture person")
  }
}
enum ImportedCredentialProbe {
  static func mobileOwner(_ token:String)async throws->Int64{
    try await Task.sleep(nanoseconds:70_000_000)
    _ = try MobileIdentityRequest.make(token,device:"fixture-buvid",timestamp:1_700_000_000)
    let uid=token=="fixture-access-token" ? 100 : 200
    return try MobileIdentityRequest.owner(Data("{\"code\":0,\"data\":{\"mid\":\(uid)}}".utf8),status:200)
  }
}
actor BiliAPI {static let shared=BiliAPI()}
actor AccountJar {
  static let shared=AccountJar();var generation:UInt64=0,active:String?,saved=0
  func packStamp()throws->(generation:UInt64,active:String?){(generation,active)}
  func reset(_ owner:String?=nil){generation &+= 1;active=owner;saved=0}
  func changed(){generation &+= 1}
  func count()->Int{saved}
  func addSession(_ cookies:[String:String],token:String,refresh:String?,device:String?,label:String,expectedGeneration:UInt64?=nil)throws{
    try Task.checkCancellation()
    guard expectedGeneration==generation else{throw ServiceError("账号已变更，请重新登录")}
    precondition(cookies["DedeUserID"]=="100" && token=="fixture-access-token")
    active="100";generation &+= 1;saved+=1
  }
}
actor SyntheticPassport {
  var requests=[[String:String]]()
  let pem:String;var qrPolls=0
  init(_ pem:String){self.pem=pem}
  static var cookies:[[String:String]]{[["name":"DedeUserID","value":"100"],["name":"SESSDATA","value":"fixture-cookie-100"],["name":"bili_jct","value":"fixture-csrf"]]}
  static var session:[String:Any]{["token_info":["mid":100,"access_token":"fixture-access-token","refresh_token":"fixture-refresh"],"cookie_info":["cookies":cookies]]}
  func send(_ request:URLRequest)async throws->Data{
    let path=request.url!.path,body=String(data:request.httpBody ?? Data(),encoding:.utf8) ?? ""
    requests.append(["url":request.url!.absoluteString,"method":request.httpMethod ?? "GET","body":body,"cookie":request.value(forHTTPHeaderField:"Cookie") ?? "","authorization":request.value(forHTTPHeaderField:"Authorization") ?? "","referer":request.value(forHTTPHeaderField:"Referer") ?? ""])
    let fields=Dictionary(uniqueKeysWithValues:(URLComponents(string:"https://fixture/?"+(body.isEmpty ? (request.url!.query ?? "") : body))!.queryItems ?? []).map{($0.name,$0.value ?? "")})
    precondition(request.url!.host=="passport.bilibili.com" && request.url!.scheme=="https")
    var code=0,data=[String:Any]()
    switch path {
    case "/x/passport-login/web/key":data=["hash":"fixture-salt:","key":pem]
    case "/x/passport-tv-login/qrcode/auth_code":data=["auth_code":"fixture-auth-code","url":"https://passport.bilibili.com/x/passport-tv-login/h5/qrcode/auth?auth_code=fixture-auth-code"]
    case "/x/passport-tv-login/qrcode/poll":
      qrPolls+=1
      if qrPolls==1{code=86039}else if qrPolls==2{code=86090}else{data=["access_token":"fixture-access-token","refresh_token":"fixture-refresh","mid":100,"cookie_info":["cookies":Self.cookies]]}
    case "/x/passport-login/oauth2/login":
      if fields["gee_validate"]==nil{
        code = -105;data=["url":"https://passport.bilibili.com/h5-app/passport/captcha?gee_gt=fixture-gt&gee_challenge=fixture-challenge&recaptcha_token=fixture-recaptcha"]
      }else{data=["status":2,"url":"https://passport.bilibili.com/h5-app/passport/risk/verify?tmp_token=fixture-risk&request_id=fixture-request&source=risk"]}
    case "/x/passport-login/sms/send":
      if fields["gee_validate"]==nil{data=["recaptcha_url":"https://passport.bilibili.com/empty-captcha"]}
      else{data=["recaptcha_url":"","captcha_key":"fixture-sms-key"]}
    case "/x/passport-login/login/sms":data=Self.session
    case "/x/safecenter/user/info":data=["account_info":["tel_verify":true,"hide_tel":"123****456"]]
    case "/x/safecenter/captcha/pre":data=["gee_gt":"fixture-gt","gee_challenge":"fixture-challenge","recaptcha_token":"fixture-recaptcha"]
    case "/x/safecenter/common/sms/send":data=["captcha_key":"fixture-risk-sms"]
    case "/x/safecenter/login/tel/verify":data=["code":"fixture-oauth-code"]
    case "/x/passport-login/oauth2/access_token":data=Self.session
    default:preconditionFailure("unhandled synthetic endpoint")
    }
    return try JSONSerialization.data(withJSONObject:["code":code,"message":"fixture","data":data])
  }
  func export()throws{
    try JSONSerialization.data(withJSONObject:requests).write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("requests.json"))
  }
}
@main enum PassportCheck {
  @MainActor static func solve(_ flow:NativeLoginFlow,_ solution:MobileCaptchaSolution){
    guard let id=flow.captcha?.id else{preconditionFailure("missing synthetic challenge")}
    flow.solved(solution,challengeID:id)
  }
  @MainActor static func wait(_ flow:NativeLoginFlow)async throws{
    for _ in 0..<200{if !flow.busy{return};try await Task.sleep(nanoseconds:5_000_000)}
    preconditionFailure("synthetic flow did not settle")
  }
  @MainActor static func main()async throws{
    let root=URL(fileURLWithPath:CommandLine.arguments[1])
    let pem=try String(contentsOf:root.appendingPathComponent("public.pem"),encoding:.utf8)
    let pkcs1=try Data(contentsOf:root.appendingPathComponent("pkcs1.der"))
    let unwrapped=try MobilePasswordCipher.publicKeyDER(pem);precondition(unwrapped==pkcs1)
    let rsaPEM="-----BEGIN RSA PUBLIC KEY-----\n"+pkcs1.base64EncodedString()+"\n-----END RSA PUBLIC KEY-----"
    let rawKey=try MobilePasswordCipher.publicKeyDER(rsaPEM);precondition(rawKey==pkcs1)
    do{_ = try MobilePasswordCipher.publicKeyDER("-----BEGIN PUBLIC KEY-----\nMAA=\n-----END PUBLIC KEY-----");preconditionFailure("malformed key accepted")}catch{}
    let vector=MobileClientSigning.signed(["z":"中文 +/!~*'()","a":"1&2=3"],timestamp:1_700_000_000)
    try JSONSerialization.data(withJSONObject:vector).write(to:root.appendingPathComponent("signature.json"))
    var probes=[[String:String]]()
    for token in ["fixture-access-token","fixture&+!~*'()"] {
      let request=try MobileIdentityRequest.make(token,device:"probe-device",timestamp:1_700_000_000)
      precondition(!request.httpShouldHandleCookies && request.value(forHTTPHeaderField:"Cookie")==nil && request.value(forHTTPHeaderField:"Authorization")==nil && request.value(forHTTPHeaderField:"x-bili-mid")==nil)
      precondition(request.value(forHTTPHeaderField:"buvid")=="probe-device" && request.value(forHTTPHeaderField:"User-Agent")==MobileClientSigning.userAgent)
      probes.append(["url":request.url!.absoluteString,"input":token])
    }
    try JSONSerialization.data(withJSONObject:probes).write(to:root.appendingPathComponent("identity-probes.json"))
    let owner=try MobileIdentityRequest.owner(Data(#"{"code":0,"data":{"mid":100}}"#.utf8),status:200)
    precondition(owner==100)
    for (body,status) in [(#"{"code":0,"data":{"mid":100}}"#,401),(#"{"code":-101,"data":{"mid":100}}"#,200),(#"{"code":0,"data":{"mid":0}}"#,200),(#"{"code":0,"data":{}}"#,200)] {
      do{_ = try MobileIdentityRequest.owner(Data(body.utf8),status:status);preconditionFailure("rejected identity reply was accepted")}catch let e as ServiceError{precondition(e.message.contains("无效或已过期"))}
    }
    for token in ["", "short", "fixture\ninvalid"] {
      do{_ = try MobileIdentityRequest.make(token,device:"probe-device");preconditionFailure("invalid identity token sent")}catch let e as ServiceError{precondition(e.message.contains("格式无效"))}
    }
    let delegated=try await BiliAPI.shared.mobileIdentity("fixture-access-token");precondition(delegated==100)
    let server=SyntheticPassport(pem)
    let api=MobilePassport(buvid:"fixture-buvid",deviceID:"fixture-device",transport:{try await server.send($0)})
    let ticket=try await api.qrTicket()
    guard case .waiting=try await api.qrPoll(ticket) else{preconditionFailure("QR wait")}
    guard case .scanned=try await api.qrPoll(ticket) else{preconditionFailure("QR scanned")}
    guard case .session(let qr)=try await api.qrPoll(ticket) else{preconditionFailure("QR credentials")}
    let verified=try await MobileLoginVerifier.verify(qr,expectedUID:"100")
    precondition(verified.token=="fixture-access-token" && verified.cookies["DedeUserID"]=="100")
    do{_ = try await MobileLoginVerifier.verify(qr,expectedUID:"200");preconditionFailure("expected UID bypass")}catch let e as ServiceError{precondition(e.message.contains("当前账号"))}
    let mixed=MobileLoginSession(cookies:qr.cookies,token:"fixture-wrong-owner-token",refresh:nil,device:qr.device)
    do{_ = try await MobileLoginVerifier.verify(mixed,expectedUID:nil);preconditionFailure("mixed credentials accepted")}catch let e as ServiceError{precondition(e.message.contains("当前账号"))}
    let solution=MobileCaptchaSolution(challenge:"fixture-challenge",validate:"fixture-validate",seccode:"fixture-seccode",token:"fixture-recaptcha")
    guard case .captcha=try await api.password(username:"user +!~*'()",password:"密码+1") else{preconditionFailure("password captcha")}
    guard case .risk(let risk)=try await api.password(username:"user +!~*'()",password:"密码+1",captcha:solution) else{preconditionFailure("password risk status2")}
    let masked=try await api.riskInfo(risk);precondition(masked=="123****456")
    _ = try await api.preCaptcha()
    let riskKey=try await api.sendRiskSMS(risk,captcha:solution)
    let riskSession=try await api.verifyRisk(risk,code:"123456",captchaKey:riskKey)
    _ = try await MobileLoginVerifier.verify(riskSession,expectedUID:"100")
    guard case .captcha=try await api.sendSMS(phone:"12345678",country:65) else{preconditionFailure("SMS captcha fallback")}
    guard case .sent(let smsKey)=try await api.sendSMS(phone:"12345678",country:65,captcha:solution) else{preconditionFailure("SMS send")}
    guard case .session(let sms)=try await api.sms(phone:"12345678",country:65,code:"123456",captchaKey:smsKey) else{preconditionFailure("SMS login")}
    _ = try await MobileLoginVerifier.verify(sms,expectedUID:"100")
    let device=try MobilePassport.deviceListRequest(csrf:"fixture-csrf",token:"fixture-access-token",buvid:"fixture-buvid",cookie:"DedeUserID=100; SESSDATA=fixture-cookie-100",timestamp:1_700_000_000)
    try JSONSerialization.data(withJSONObject:["url":device.url!.absoluteString,"cookie":device.value(forHTTPHeaderField:"Cookie") ?? ""]).write(to:root.appendingPathComponent("devices.json"))
    for url in ["https://evil.invalid/h5-app/passport/risk/verify?tmp_token=a&request_id=b&source=risk","https://passport.bilibili.com/h5-app/passport/risk/verify?tmp_token=a&tmp_token=b&request_id=c&source=risk"]{
      do{_ = try MobileRiskContext(url);preconditionFailure("untrusted risk URL accepted")}catch{}
    }
    // Drive the real UI flow through captcha -> risk -> captcha -> SMS -> OAuth -> one atomic save.
    await AccountJar.shared.reset()
    let flow=NativeLoginFlow(expectedUID:nil,api:api);flow.activate();flow.password("flow-user","flow-password")
    try await wait(flow);precondition(flow.captcha != nil)
    let challengeID=flow.captcha!.id
    flow.solved(solution,challengeID:UUID());precondition(flow.captcha?.id==challengeID)
    solve(flow,solution);try await wait(flow);precondition(flow.risk != nil)
    flow.sendRiskSMS();try await wait(flow);precondition(flow.captcha != nil)
    solve(flow,solution);try await wait(flow)
    flow.verifyRisk("123456");try await wait(flow);precondition(flow.completedUID=="100")
    let count=await AccountJar.shared.count();precondition(count==1);flow.cancel()
    // Leaving, account replacement and wrong-target authorization cannot publish late credentials.
    await AccountJar.shared.reset()
    let cancelled=NativeLoginFlow(expectedUID:nil,api:api);cancelled.activate()
    cancelled.sendSMS("12345678",65,solution:solution);try await wait(cancelled)
    cancelled.sms("12345678",65,"123456");try await Task.sleep(nanoseconds:15_000_000);cancelled.cancel()
    try await Task.sleep(nanoseconds:150_000_000)
    let cancelledCount=await AccountJar.shared.count();precondition(cancelledCount==0)
    await AccountJar.shared.reset("200")
    let wrong=NativeLoginFlow(expectedUID:"200",api:api);wrong.activate();wrong.password("target-user","target-password",solution:solution)
    try await wait(wrong)
    wrong.sendRiskSMS();try await wait(wrong);solve(wrong,solution);try await wait(wrong);wrong.verifyRisk("123456")
    try await wait(wrong);let wrongCount=await AccountJar.shared.count();precondition(wrongCount==0 && wrong.completedUID==nil);wrong.cancel()
    await AccountJar.shared.reset()
    let stale=NativeLoginFlow(expectedUID:nil,api:api);stale.activate()
    stale.sendSMS("12345678",65,solution:solution);try await wait(stale)
    stale.sms("12345678",65,"123456");try await Task.sleep(nanoseconds:15_000_000);await AccountJar.shared.changed()
    try await wait(stale);let staleCount=await AccountJar.shared.count();precondition(staleCount==0 && stale.completedUID==nil);stale.cancel()
    try await server.export()
    if CommandLine.arguments.contains("--anonymous") {
      do {
        let keyRequest=try MobilePassport.request(path:"/x/passport-login/web/key",method:"GET",signed:false,buvid:"anonymous-probe")
        let keyBytes=try await MobilePassportNetwork.send(keyRequest)
        let json=try JSONSerialization.jsonObject(with:keyBytes) as! [String:Any]
        guard json["code"] as? Int==0,let key=(json["data"] as? [String:Any])?["key"] as? String else{throw ServiceError("public-key reply rejected")}
        _ = try MobilePasswordCipher.publicKeyDER(key)
        let anonymous=MobilePassport(buvid:"anonymous-probe")
        let anonymousTicket=try await anonymous.qrTicket()
        guard case .waiting=try await anonymous.qrPoll(anonymousTicket) else{throw ServiceError("unscanned QR poll returned unexpected state")}
        print("Anonymous public key, signed QR generation and unscanned poll passed; no identifiers retained")
      } catch {print("Anonymous connectivity unavailable: \(error.localizedDescription)");exit(3)}
    }
    print("Mobile passport: production encoding/signing, QR, RSA password/captcha/risk/OAuth, international SMS, owner binding, cancellation and generation guard passed")
  }
}
'''

with tempfile.TemporaryDirectory(prefix="pili-mobile-passport-") as temp:
    work = Path(temp)
    subprocess.run(["openssl", "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:1024", "-out", str(work/"private.pem")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["openssl", "pkey", "-in", str(work/"private.pem"), "-pubout", "-out", str(work/"public.pem")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["openssl", "rsa", "-in", str(work/"private.pem"), "-RSAPublicKey_out", "-outform", "DER", "-out", str(work/"pkcs1.der")], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    signing=(source/"MobileClientSigning.swift").read_text().replace("import CryptoKit", "")
    cipher=(source/"MobilePasswordCipher.swift").read_text().replace("import Security", "").split("enum MobileRSA {",1)[0]
    passport=(source/"MobilePassport.swift").read_text()
    a=passport.index("enum MobilePassportNetwork {"); b=passport.index("enum MobileLoginVerifier {", a)
    passport=passport[:a]+passport[b:]
    flow=(source/"NativeLoginFlow.swift").read_text().replace("import SwiftUI", "import Foundation").replace("@Published ", "").replace(": ObservableObject", "")
    identity=(source/"ImportedCredentialProbe.swift").read_text().split("enum ImportedCredentialProbe {",1)[0]
    authorization=(source/"MobileAuthorization.swift").read_text().split("extension BiliAPI {",1)[1].split("  nonisolated func instantMessaging",1)[0]
    delegate="extension BiliAPI {"+authorization+"}\n"
    files=[]
    for name, text in [("Signing",signing),("Cipher",cipher),("Passport",passport),("Flow",flow),("IdentityRequest",identity),("IdentityDelegate",delegate),("Fixture",fixture)]:
        path=work/(name+".swift");path.write_text("import FoundationNetworking\n"+text);files.append(str(path))
    subprocess.run(["swiftc",str(native/"Sources/PiliNative/Network/ServiceError.swift"),*files,"-o",str(work/"check")],check=True)
    run=subprocess.run([str(work/"check"),str(work),*sys.argv[1:]],check=False)
    if run.returncode:raise SystemExit(run.returncode)
    public_constants=subprocess.check_output(["git","show","d9e9626f1a3f89cd9ca85e18f61aaba02634e12a:lib/common/constants.dart"],cwd=native.parent,text=True)
    appkey=re.search(r"appKey\s*=\s*'([^']+)'",public_constants)[1]
    appsecret=re.search(r"appSec\s*=\s*'([^']+)'",public_constants)[1]
    def canonical(fields):
        return "&".join(quote(k,safe="-_.!~*'()")+"="+quote(v,safe="-_.!~*'()") for k,v in sorted(fields.items()))
    def require_signature(fields):
        assert fields["appkey"]==appkey
        signed=dict(fields);signature=signed.pop("sign")
        assert signature==hashlib.md5((canonical(signed)+appsecret).encode()).hexdigest()
    vector=json.loads((work/"signature.json").read_text());require_signature(vector)
    assert canonical({"z":vector["z"]})=="z=%E4%B8%AD%E6%96%87%20%2B%2F!~*'()"
    requests=json.loads((work/"requests.json").read_text())
    seen=set(); passwords=[];dt=[]
    unsigned={"/x/passport-login/web/key","/x/safecenter/captcha/pre","/x/safecenter/user/info"}
    for row in requests:
        url=urlsplit(row["url"]);seen.add(url.path)
        fields=dict(parse_qsl(row["body"] or url.query,keep_blank_values=True))
        assert not row["cookie"] and not row["authorization"]
        if url.path not in unsigned:require_signature(fields)
        if "/qrcode/" in url.path:assert row["method"]=="POST" and not row["body"]
        if "/safecenter/common/" in url.path or "/safecenter/login/" in url.path:assert row["referer"].startswith("https://passport.bilibili.com/h5-app/passport/risk/verify?")
        if "password" in fields:passwords.append(fields)
        if "dt" in fields:dt.append(fields["dt"])
        if url.path.endswith("/login/sms"):assert fields["tel"]=="12345678" and fields["cid"]=="65" and fields["captcha_key"]=="fixture-sms-key"
    assert len(seen)==11 and len(passwords)>=2
    def decrypt(ciphertext):
        import base64
        return subprocess.check_output(["openssl","pkeyutl","-decrypt","-inkey",str(work/"private.pem"),"-pkeyopt","rsa_padding_mode:pkcs1"],input=base64.b64decode(ciphertext))
    assert decrypt(passwords[0]["password"])=="fixture-salt:密码+1".encode()
    assert len({p["password"] for p in passwords[:2]})==2  # randomized PKCS#1 padding
    assert all(len(decrypt(unquote(value)))==16 for value in dt)
    devices=json.loads((work/"devices.json").read_text());fields=dict(parse_qsl(urlsplit(devices["url"]).query))
    require_signature(fields);assert fields["access_key"]=="fixture-access-token" and fields["csrf"]=="fixture-csrf" and fields["statistics"]
    for probe in json.loads((work/"identity-probes.json").read_text()):
        url=urlsplit(probe["url"]);fields=dict(parse_qsl(url.query))
        assert url.scheme=="https" and url.netloc=="app.bilibili.com" and url.path=="/x/v2/account/myinfo"
        require_signature(fields);assert fields["access_key"]==probe["input"]
        assert set(fields)=={"access_key","mobi_app","platform","appkey","ts","sign"}
    original=subprocess.check_output(["git","show","d9e9626f1a3f89cd9ca85e18f61aaba02634e12a:lib/common/dial_prefix.dart"],cwd=native.parent,text=True)
    regions=re.findall(r'\(id:\s*(\d+),\s*cname:\s*"([^"]+)",\s*countryId:\s*(\d+)\)',original)
    migrated=re.findall(r'\.init\(id:\s*(\d+),\s*name:\s*"([^"]+)",\s*code:\s*(\d+)\)',(source/"LoginRegions.swift").read_text())
    assert migrated==regions and len(regions)==215
    print("Independent Python/OpenSSL oracle: all 11 login paths, exact Dart URI signature, PKCS#1 password/dt, signed devices and token-only identity probes, all 215 regions passed")
