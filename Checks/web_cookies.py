"""Run production web Cookie/AccountJar/fetch/submit code with memory Keychain and synthetic replies."""
from pathlib import Path
import subprocess, tempfile

native = Path(__file__).resolve().parents[1]
source = native / "Sources/PiliNative"
accounts = (source/"Account/Accounts.swift").read_text().split("@MainActor final class AccountContext", 1)[0]
for module in ("PiliArchive", "Security", "SwiftUI"):
    accounts = accounts.replace("import " + module + "\n", "")
a = accounts.index("  private let fields:"); b = accounts.index("  func presentedState()", a)
accounts = accounts[:a] + '''  func state() throws -> State { cached ?? State() }
  private func persist(_ value:State) throws { cached=value; packGeneration &+= 1 }
  func fixtureLoad(_ value:State) { cached=value; temporaryPrivateOwner=nil; packGeneration &+= 1 }
''' + accounts[b:]
a = accounts.index("  func clearForLocalReset()"); b = accounts.index("  func forgetSession", a)
accounts = accounts[:a] + "  func clearForLocalReset() throws {cached=State();temporaryPrivateOwner=nil;packGeneration &+= 1}\n" + accounts[b:]
api = (source/"Network/BiliAPI.swift").read_text()
fetch = api[api.index("  func fetch("):api.index("  func read<")]
read = api[api.index("  func read<"):api.index("  private struct Status:")]
submit = api[api.index("  enum FormService:"):api.index("  func recommendations(")]
api = '''import Foundation
import FoundationNetworking
actor BiliAPI {
  static let shared=BiliAPI(); let session=FixtureSession(); private let agent="fixture"
  private struct Envelope<T:Decodable>:Decodable{let code:Int,message:String?,data:T?,result:T?}
  private struct Status:Decodable{let code:Int,message:String?}
  func mobileREST(_ path:String,_ query:[String:String],use:AccountUse,expectedAccount:String?)async throws->(data:Data,http:HTTPURLResponse){
    let response=try await session.response(for:URLRequest(url:URL(string:"https://app.bilibili.com"+path)!))
    return(response.data,response.http)
  }
''' + fetch + read + submit + "}\n"

fixture = r'''
import Foundation
import FoundationNetworking
typealias ArchiveIssue=ServiceError
enum MobileDeviceID {
  static let guestKey="fixture-device-never-written"
  static func guest()->String{"fixture-mobile-guest"}
  static func use(_ value:String?)->String{value ?? guest()}
  static func valid(_ value:String)->Bool{!value.isEmpty}
  static func forRead(host:String,path:String)->Bool{false}
}
struct ConnectionRetry {
  static func current()->Self{Self()}
  func perform<T>(readOnly:Bool,_ send:(Int)async throws->T)async throws->T{try await send(0)}
}
enum DiagnosticJournal {static func network(_ path:String,_ label:String,_ code:Int){}}
actor Trace {
  static let shared=Trace();var steps=[String]()
  func add(_ value:String){steps.append(value)}
  func reset(){steps=[]}
  func values()->[String]{steps}
}
actor DeviceActivationService {static let shared=DeviceActivationService();func refresh()async{await Trace.shared.add("activation")}}
func cookie(_ name:String,_ value:String,domain:String=".bilibili.com",path:String="/",expires:Date?=nil)->HTTPCookie{
  var p:[HTTPCookiePropertyKey:Any]=[.name:name,.value:value,.domain:domain,.path:path,.secure:"TRUE"]
  if let expires{p[.expires]=expires};return HTTPCookie(properties:p)!
}
actor Probe {
  static let shared=Probe();var mode="normal",delay:UInt64=0,issued=[HTTPCookie](),checks=0
  func set(_ mode:String="normal",delay:UInt64=0,issued:[HTTPCookie]=[]){self.mode=mode;self.delay=delay;self.issued=issued}
  func count()->Int{checks}
  func inspect(_ values:[String:String])async throws->WebLoginInspection{
    checks+=1;await Trace.shared.add("nav")
    let state=(mode,delay,issued)
    if state.1>0{try await Task.sleep(nanoseconds:state.1)}
    if state.0=="offline"{throw URLError(.timedOut)}
    if state.0=="risk"{throw ServiceError("synthetic risk challenge",code:-352)}
    if state.0=="invalid"{throw ServiceError("账号未登录",code:-101)}
    var result=values
    result["DedeUserID"]=(values["SESSDATA"] ?? "").hasPrefix("B") ? "200":"100"
    let update=try WebCookieJar.update(legacy:result,stored:[],cookies:state.2,from:URL(string:"https://api.bilibili.com/x/web-interface/nav")!,owner:result["DedeUserID"])
    return .init(cookies:WebCookieJar.root(update.legacy,update.stored),name:"fixture",responseCookies:state.2)
  }
}
enum WebLoginIdentity {
  static func inspect(_ values:[String:String])async throws->WebLoginInspection{try await Probe.shared.inspect(values)}
  static func verify(_ values:[String:String])async throws->(cookies:[String:String],name:String){let r=try await inspect(values);return(r.cookies,r.name)}
}
enum ImportedCredentialProbe {static func mobileOwner(_ token:String)async throws->Int64{token.hasPrefix("B") ? 200:100}}
actor Wire {
  static let shared=Wire();var body=#"{"code":0,"data":{}}"#,cookies=[HTTPCookie](),status=200,delay:UInt64=0
  var requests=[URLRequest]()
  func set(_ body:String = #"{"code":0,"data":{}}"#,cookies:[HTTPCookie]=[],status:Int=200,delay:UInt64=0){self.body=body;self.cookies=cookies;self.status=status;self.delay=delay}
  func send(_ request:URLRequest)async throws->(data:Data,http:HTTPURLResponse,cookies:[HTTPCookie]){
    let reply=(body,cookies,status,delay);requests.append(request)
    if reply.3>0{try? await Task.sleep(nanoseconds:reply.3)} // Intentionally return after cancellation.
    return(Data(reply.0.utf8),HTTPURLResponse(url:request.url!,statusCode:reply.2,httpVersion:nil,headerFields:nil)!,reply.1)
  }
  func last()->URLRequest{requests.last!}
}
struct FixtureSession {
  func response(for request:URLRequest)async throws->(data:Data,http:HTTPURLResponse,cookies:[HTTPCookie]){try await Wire.shared.send(request)}
  func data(for request:URLRequest)async throws->(Data,URLResponse){let r=try await response(for:request);return(r.data,r.http)}
}
final class Notifications:@unchecked Sendable {
  private let lock=NSLock();private var values=[String]()
  func add(_ uid:String){lock.lock();values.append(uid);lock.unlock()}
  func all()->[String]{lock.lock();defer{lock.unlock()};return values}
}
final class FixtureRedirectPolicy:CertificateSessionDelegate,@unchecked Sendable {
  var decisions=0
  override func urlSession(_ session:URLSession,task:URLSessionTask,willPerformHTTPRedirection response:HTTPURLResponse,newRequest request:URLRequest,completionHandler:@escaping(URLRequest?)->Void){
    decisions+=1
    guard let original=task.originalRequest,let from=original.url,let to=request.url,
      HTTP11Message.allowsRedirect(method:original.httpMethod ?? "GET",from:from,to:to) else{completionHandler(nil);return}
    completionHandler(request)
  }
}
@main enum WebCookieCheck {
  static let jar=AccountJar.shared,api=BiliAPI.shared
  static func identity(_ uid:String,_ session:String)->Identity{
    Identity(id:uid,label:"fixture "+uid,cookies:["DedeUserID":uid,"SESSDATA":session,"bili_jct":"csrf-"+uid,"buvid3":"visitor-"+uid],mobileToken:"token-"+uid)
  }
  static func reset()async throws{
    var routes=AccountRoutes();routes.set(.video,choice:"200");routes.set(.recommend,choice:"100")
    await jar.fixtureLoad(.init(accounts:[identity("100","A-live"),identity("200","B-live")],active:"100",routes:routes))
    await Probe.shared.set();await Wire.shared.set();await Trace.shared.reset()
  }
  static func state()async throws->AccountJar.State{try await jar.state()}
  static func snapshot(_ uid:String?="100")async throws->WebSessionSnapshot{try await jar.webSnapshot(owner:uid)}
  static func fetch(_ path:String="/x/fixture",host:String="api.bilibili.com",owner:String="100",video:Bool=false)async throws->Data{
    try await api.fetch(path,[:],host:host,expectedAccount:owner,cacheVideoIdentity:video)
  }
  static func main()async throws{
    let notices=Notifications()
    let watch=NotificationCenter.default.addObserver(forName:InvalidWebSession.notification,object:nil,queue:nil){note in if let uid=note.object as? String{notices.add(uid)}}
    defer{NotificationCenter.default.removeObserver(watch)}
    let origin=URL(string:"https://api.bilibili.com/x/private/item")!,now=Date()
    let initial=["DedeUserID":"100","SESSDATA":"A-live","bili_jct":"csrf-100","gone":"old"]
    let parsed=HTTPCookie.cookies(withResponseHeaderFields:["Set-Cookie":"host_ticket=one; Path=/x/private; Secure"],for:origin)
    let updated=try WebCookieJar.update(legacy:initial,stored:[],cookies:parsed+[cookie("root_ticket","root"),cookie("bad","evil",domain:"evil.invalid"),cookie("gone","old",expires:now.addingTimeInterval(-10))],from:origin,owner:"100",now:now)
    let here=WebCookieJar.values(updated.legacy,updated.stored,for:origin,now:now)
    precondition(here["host_ticket"]=="one" && here["root_ticket"]=="root" && here["bad"]==nil && here["gone"]==nil)
    precondition(WebCookieJar.values(updated.legacy,updated.stored,for:URL(string:"https://api.bilibili.com/x/privateish")!,now:now)["host_ticket"]==nil)
    precondition(WebCookieJar.values(updated.legacy,updated.stored,for:URL(string:"https://www.bilibili.com/x/private/item")!,now:now)["host_ticket"]==nil)
    precondition(WebCookieJar.values(updated.legacy,updated.stored,for:URL(string:"http://api.bilibili.com/x/private/item")!,now:now).isEmpty)
    precondition(WebCookieJar.values(updated.legacy,updated.stored,for:URL(string:"https://app.bilibili.com/x/private/item")!,now:now).isEmpty)
    // Exercise the shipping per-request collector and the actual shared redirect predicate.
    // The URLSession task is never resumed; only synthetic redirect callbacks are delivered.
    let redirectSession=URLSession(configuration:.ephemeral),policy=FixtureRedirectPolicy(),capture=ResponseCookieCapture(forwarding:FixtureRedirectPolicy())
    let start=URL(string:"https://api.bilibili.com/x/start")!
    let task=redirectSession.dataTask(with:start)
    let response=HTTPURLResponse(url:start,statusCode:302,httpVersion:nil,headerFields:["Set-Cookie":"step_ticket=step; Path=/x/start; Secure"])!
    let forwarding=ResponseCookieCapture(forwarding:policy)
    var followed=false
    forwarding.urlSession(redirectSession,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:URL(string:"https://api.bilibili.com/x/end")!)){followed=$0 != nil}
    precondition(followed && policy.decisions==1 && forwarding.cookies.count==1)
    precondition(ResponseCookieOrigin.source(forwarding.cookies[0],fallback:origin)==start)
    let hop=try WebCookieJar.update(legacy:initial,stored:[],cookies:forwarding.cookies,from:URL(string:"https://www.bilibili.com/x/end")!,owner:"100")
    precondition(WebCookieJar.values(hop.legacy,hop.stored,for:start)["step_ticket"]=="step")
    precondition(WebCookieJar.values(hop.legacy,hop.stored,for:URL(string:"https://www.bilibili.com/x/start")!)["step_ticket"]==nil)
    forwarding.urlSession(redirectSession,task:task,willPerformHTTPRedirection:response,newRequest:URLRequest(url:URL(string:"https://evil.invalid/x/end")!)){followed=$0 != nil}
    precondition(!followed && policy.decisions==2 && forwarding.cookies.count==1)
    var post=URLRequest(url:start);post.httpMethod="POST";let postTask=redirectSession.dataTask(with:post)
    capture.urlSession(redirectSession,task:postTask,willPerformHTTPRedirection:response,newRequest:URLRequest(url:origin)){followed=$0 != nil}
    precondition(!followed && capture.cookies.isEmpty)
    task.cancel();postTask.cancel();redirectSession.invalidateAndCancel()
    let expiring=try WebCookieJar.update(legacy:initial,stored:[],cookies:[cookie("temporary","v",expires:now.addingTimeInterval(10))],from:origin,owner:"100",now:now)
    precondition(WebCookieJar.values(expiring.legacy,expiring.stored,for:origin,now:now.addingTimeInterval(20))["temporary"]==nil)
    let afterExpiry=try WebCookieJar.update(legacy:expiring.legacy,stored:expiring.stored,cookies:[cookie("other","v")],from:origin,owner:"100",now:now.addingTimeInterval(20))
    precondition(WebCookieJar.values(afterExpiry.legacy,afterExpiry.stored,for:origin,now:now.addingTimeInterval(20))["temporary"]==nil)
    do{_ = try WebCookieJar.update(legacy:initial,stored:[],cookies:[cookie("DedeUserID","200")],from:origin,owner:"100");preconditionFailure("foreign UID accepted")}catch let e as ServiceError{precondition(e.message.contains("不匹配"))}
    try await reset()
    await Wire.shared.set(cookies:[cookie("bili_ticket","first"),cookie("host_ticket","scoped",domain:"api.bilibili.com",path:"/x/private")])
    _ = try await fetch("/x/private/item")
    let sent=await Wire.shared.last();precondition(sent.value(forHTTPHeaderField:"Cookie")?.contains("SESSDATA=A-live")==true)
    let stored=try await snapshot();precondition(stored.cookies["bili_ticket"]=="first" && stored.header(for:origin).contains("host_ticket=scoped"))
    await Wire.shared.set();_ = try await fetch("/x/private/item");let scoped=await Wire.shared.last()
    precondition(scoped.value(forHTTPHeaderField:"Cookie")?.contains("host_ticket=scoped")==true)
    _ = try await fetch("/x/private/item",host:"www.bilibili.com");let cross=await Wire.shared.last()
    precondition(cross.value(forHTTPHeaderField:"Cookie")?.contains("host_ticket=scoped") != true)
    let beforeApp=try await snapshot()
    await Wire.shared.set(#"{"code":-101}"#,cookies:[cookie("bili_ticket","app-must-not-save")])
    _ = try await fetch("/x/v2/account/myinfo",host:"app.bilibili.com")
    let afterApp=try await snapshot();precondition(afterApp==beforeApp)
    // A normal POST rotation is verified once; its verifying nav may rotate again.
    await Probe.shared.set(issued:[cookie("SESSDATA","A-checked"),cookie("bili_jct","csrf-checked"),cookie("nav_host_ticket","proof",domain:"api.bilibili.com",path:"/x")])
    await Wire.shared.set(cookies:[cookie("SESSDATA","A-rotated"),cookie("bili_jct","csrf-rotated")])
    try await api.submit("/x/fixture/write",["message":"fixture"],expectedAccount:"100")
    let rotated=try await snapshot(),other=try await snapshot("200")
    precondition(rotated.cookies["SESSDATA"]=="A-checked" && rotated.cookies["bili_jct"]=="csrf-checked")
    precondition(rotated.header(for:origin).contains("nav_host_ticket=proof") && other.cookies["SESSDATA"]=="B-live")
    await Probe.shared.set()
    let bound=try await snapshot();let checks=await Probe.shared.count();let notified=notices.all()
    async let left=jar.mergeResponseCookies([cookie("ticket_left","L")],from:origin,bound:bound)
    async let right=jar.mergeResponseCookies([cookie("ticket_right","R")],from:origin,bound:bound)
    _ = try await left;_ = try await right
    _ = try await jar.mergeResponseCookies([cookie("ticket_left","L",expires:Date().addingTimeInterval(60))],from:origin,bound:bound)
    let concurrent=try await snapshot();let afterChecks=await Probe.shared.count()
    precondition(concurrent.cookies["ticket_left"]=="L" && concurrent.cookies["ticket_right"]=="R" && concurrent.sameIdentity(as:bound))
    precondition(checks==afterChecks && notices.all()==notified)
    // Cancellation and a same-UID token replacement cannot import a stale response.
    await Wire.shared.set(cookies:[cookie("cancelled_ticket","bad")],delay:70_000_000)
    let cancelled=Task{try await fetch()};try await Task.sleep(nanoseconds:10_000_000);cancelled.cancel()
    do{_ = try await cancelled.value;preconditionFailure("cancelled cookie accepted")}catch is CancellationError{}
    let cancelledJar=try await snapshot();precondition(cancelledJar.cookies["cancelled_ticket"]==nil)
    await Wire.shared.set(cookies:[cookie("stale_ticket","bad")],delay:70_000_000)
    let stale=Task{try await fetch()};try await Task.sleep(nanoseconds:10_000_000);try await jar.setMobileToken("replacement-token",for:"100")
    do{_ = try await stale.value;preconditionFailure("changed session accepted stale cookie")}catch let e as ServiceError{precondition(e.message.contains("切换"))}
    let staleJar=try await snapshot();precondition(staleJar.cookies["stale_ticket"]==nil)
    // Ordinary -101, risk and HTTP errors do not revoke the main account; cookies still merge.
    try await reset();await Wire.shared.set(#"{"code":-101,"message":"账号未登录"}"#,cookies:[cookie("error_ticket","kept")])
    do{let _:String=try await api.read("/x/fixture",[:],as:String.self);preconditionFailure("ordinary -101 not returned")}catch let e as ServiceError{precondition(e.code == -101)}
    let ordinary=try await state(),ordinaryCookies=try await snapshot();precondition(ordinary.active=="100" && ordinaryCookies.cookies["error_ticket"]=="kept")
    await Wire.shared.set(#"{"code":-352,"message":"验证"}"#,cookies:[cookie("risk_ticket","kept")])
    _ = try await fetch("/x/web-interface/nav");let risk=try await state();precondition(risk.active=="100")
    await Wire.shared.set(#"{"code":-101}"#,status:503)
    do{_ = try await fetch("/x/web-interface/nav");preconditionFailure("HTTP error not returned")}catch{}
    let httpError=try await state();precondition(httpError.active=="100")
    // A non-main video identity gets its own error cookie, never deletion of the main identity.
    await Wire.shared.set(#"{"code":-101,"message":"账号未登录"}"#,cookies:[cookie("video_error_ticket","kept")])
    do{_ = try await fetch("/x/web-interface/nav",owner:"200",video:true);preconditionFailure("invalid video nav accepted")}catch let e as ServiceError{precondition(e.code == -101)}
    let videoState=try await state(),videoCookies=try await snapshot("200")
    precondition(videoState.active=="100" && videoCookies.cookies["video_error_ticket"]=="kept" && videoState.accounts.count==2)
    // A late invalid nav cannot delete a new same-UID login or an account selected meanwhile.
    await Wire.shared.set(#"{"code":-101}"#,delay:70_000_000)
    let oldInvalid=Task{try await fetch("/x/web-interface/nav")};try await Task.sleep(nanoseconds:10_000_000)
    try await jar.addSession(["DedeUserID":"100","SESSDATA":"A-new-login","bili_jct":"new-csrf"],token:"new-login-token",refresh:nil,device:"new-device",label:"fresh")
    do{_ = try await oldInvalid.value;preconditionFailure("old invalid response accepted")}catch{}
    let fresh=try await state();precondition(fresh.active=="100" && fresh.accounts.first{$0.id=="100"}?.label=="fresh")
    await Wire.shared.set(#"{"code":-101}"#,delay:70_000_000)
    let moved=Task{try await fetch("/x/web-interface/nav")};try await Task.sleep(nanoseconds:10_000_000);try await jar.select("200")
    do{_ = try await moved.value;preconditionFailure("switched account accepted old invalid response")}catch{}
    let movedState=try await state();precondition(movedState.active=="200" && movedState.accounts.count==2)
    // The actual nav false result removes only its bound main account and publishes one event.
    try await reset();let beforeNotice=notices.all().count
    await Wire.shared.set(#"{"code":0,"data":{"isLogin":false}}"#,cookies:[cookie("expired_ticket","ignored-after-delete")])
    do{_ = try await fetch("/x/web-interface/nav");preconditionFailure("logged-out nav accepted")}catch let e as ServiceError{precondition(e.code == -101)}
    let expired=try await state();precondition(expired.active==nil && expired.accounts.map(\.id)==["200"] && expired.owner(.role(.video))=="200" && expired.owner(.role(.recommend))==nil)
    precondition(notices.all().count==beforeNotice+1 && notices.all().last=="100")
    // Guest responses remain independent and cannot silently create an authenticated session.
    let guest=try await snapshot(nil);await Wire.shared.set(#"{"code":-101,"data":{"wbi_img":{}}}"#,cookies:[cookie("bili_ticket","guest"),cookie("SESSDATA","B-illegal"),cookie("DedeUserID","200")])
    _ = try await fetch("/x/web-interface/nav",owner:"")
    let guestAfter=try await snapshot(nil);precondition(guestAfter.cookies["bili_ticket"]=="guest" && guestAfter.cookies["SESSDATA"]==nil && guestAfter.cookies["buvid3"]==guest.cookies["buvid3"])
    let exported=try await jar.archiveData();precondition(!String(decoding:exported,as:UTF8.self).contains("guestResponseCookies"))
    // Explicit selection/import execute activation then nav even when ProfileView is closed.
    try await reset();await Probe.shared.set("offline");try await jar.select("200")
    let offlineSelection=try await state();precondition(offlineSelection.active=="200")
    await Probe.shared.set("risk");try await jar.select("100");let challenged=try await state();precondition(challenged.active=="100")
    await Trace.shared.reset();await Probe.shared.set("invalid");try await jar.select("100")
    let steps=await Trace.shared.values(),invalidSelection=try await state();precondition(Array(steps.suffix(2))==["activation","nav"] && invalidSelection.active==nil && invalidSelection.accounts.map(\.id)==["200"])
    try await reset();await Probe.shared.set("offline")
    try await jar.mergeArchive(["100":.init(cookies:["DedeUserID":"100","SESSDATA":"A-import","bili_jct":"csrf-import"],accessKey:nil,refresh:nil,buvid:nil,type:[0],label:nil)])
    let offlineImport=try await state();precondition(offlineImport.active=="100")
    await Probe.shared.set("invalid")
    try await jar.mergeArchive(["100":.init(cookies:["DedeUserID":"100","SESSDATA":"A-import-invalid","bili_jct":"csrf-import"],accessKey:nil,refresh:nil,buvid:nil,type:[0],label:nil)])
    let invalidImport=try await state();precondition(invalidImport.active==nil && invalidImport.accounts.map(\.id)==["200"])
    print("Web cookies: scoped/expiring real headers and per-hop origins, unchanged redirect policy, fetch/submit and proof rotation, concurrent auxiliaries, cancellation/session changes, error cookies, guest isolation, precise nav revocation and activation-before-select/import nav passed")
  }
}
'''

with tempfile.TemporaryDirectory(prefix="pili-web-cookies-") as temporary:
    work = Path(temporary)
    for name, text in (("Accounts", accounts + "\n" + fixture), ("API", api)):
        (work/(name+".swift")).write_text("import FoundationNetworking\n" + text)
    files = [source/(name+".swift") for name in (
        "Network/ServiceError", "Network/HTTP11Message", "Network/ServerCertificatePolicy", "Network/ResponseCookieOrigin", "Network/ResponseCookieCapture", "Account/ImportedCredentialProof", "Account/AccountRole", "Account/AccountServices", "Account/WebSessionCookies", "Network/WebAccountResponse")]
    files += [native/"ArchiveKit/Sources/PiliArchive/ArchiveAccount.swift", work/"Accounts.swift", work/"API.swift"]
    binary = work/"check"
    subprocess.run(["swiftc", *map(str, files), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=30)
