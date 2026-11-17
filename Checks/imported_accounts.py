"""Run production AccountJar import/role/proof code with memory-only Keychain and synthetic identity probes."""
from pathlib import Path
import subprocess, tempfile

n=Path(__file__).resolve().parents[1];s=n/"Sources/PiliNative"
text=(s/"Account/Accounts.swift").read_text().split("@MainActor final class AccountContext",1)[0]
for module in ("PiliArchive","Security","SwiftUI"):text=text.replace("import "+module+"\n","")
text="import FoundationNetworking\n"+text
a=text.index("  private let fields:");b=text.index("  func presentedState()",a)
text=text[:a]+'''  func state() throws -> State { cached ?? State() }
  private func persist(_ value:State) throws {cached=value;packGeneration &+= 1}
  func fixtureLoad(_ value:State) {cached=value}
'''+text[b:]
a=text.index("  func clearForLocalReset()");b=text.index("  func forgetSession",a)
text=text[:a]+"  func clearForLocalReset() throws {cached=State();temporaryPrivateOwner=nil;packGeneration &+= 1}\n"+text[b:]
fixtures=r'''
import Foundation
typealias ArchiveIssue=ServiceError
enum MobileDeviceID {static func guest()->String{"fixture-device"};static func use(_ value:String?)->String{value ?? guest()};static func valid(_ value:String)->Bool{!value.isEmpty};static let guestKey="fixture-never-written"}
actor MainCheckTrace {static let shared=MainCheckTrace();var steps=[String]();func mark(_ step:String){steps.append(step)};func values()->[String]{steps}}
actor DeviceActivationService {static let shared=DeviceActivationService();func refresh()async{await MainCheckTrace.shared.mark("activation")}}
actor ProbeFixture {
  static let shared=ProbeFixture();var web=0,mobile=0
  func owner(_ credential:String,isWeb:Bool) async throws -> String {
    if isWeb{web+=1}else{mobile+=1}
    try await Task.sleep(nanoseconds:50_000_000)
    if credential.hasPrefix("A"){return "100"}
    if credential.hasPrefix("B"){return "200"}
    throw ServiceError("synthetic rejected credential")
  }
  func counts()->[Int]{[web,mobile]}
}
enum WebLoginIdentity {
  static func inspect(_ values:[String:String])async throws->WebLoginInspection{
    await MainCheckTrace.shared.mark("nav")
    throw ServiceError("synthetic offline selection/import check")
  }
  static func verify(_ values:[String:String])async throws->(cookies:[String:String],name:String){
    var values=values;values["DedeUserID"]=try await ProbeFixture.shared.owner(values["SESSDATA"] ?? "",isWeb:true)
    return(values,"fixture")
  }
}
enum ImportedCredentialProbe {
  static func mobileOwner(_ token:String)async throws->Int64 {Int64(try await ProbeFixture.shared.owner(token,isWeb:false))!}
}
@main enum ImportIntegration {
  static func cookies(_ uid:String,_ value:String)->[String:String]{["DedeUserID":uid,"SESSDATA":value,"bili_jct":"synthetic-csrf"]}
  static func archive(_ uid:String,_ web:String,_ mobile:String?)->[String:ArchiveAccount]{
    [uid:.init(cookies:cookies(uid,web),accessKey:mobile,refresh:nil,buvid:nil,type:[0],label:nil)]
  }
  static func current(_ jar:AccountJar)async throws->Identity{try await jar.current()!}
  static func main()async throws{
    let jar=AccountJar()
    try await jar.add(cookies("100","A-web"),label:"previous validated login")
    let start=await ProbeFixture.shared.counts();_ = try await current(jar)
    let unchanged=await ProbeFixture.shared.counts();precondition(unchanged==start)
    try await jar.mergeArchive(archive("200","B-web","expired-mobile"))
    let mainSteps=await MainCheckTrace.shared.values();precondition(Array(mainSteps.suffix(2)) == ["activation","nav"])
    let queued=try await jar.state();precondition(queued.accounts.last?.credentialProof?.requiresValidation==true)
    let staged=await ProbeFixture.shared.counts();precondition(staged==start)
    do{_ = try await jar.localOwner();preconditionFailure("unconfirmed imported UID granted local files")}
    catch let e as ServiceError{precondition(e.message.contains("联网确认"))}
    // An expired mobile credential must neither be sent nor prevent independent Cookie-only use.
    let web=try await current(jar);precondition(web.id=="200" && web.mobileToken==nil && !web.header.isEmpty)
    let afterWeb=await ProbeFixture.shared.counts();precondition(afterWeb==[start[0]+1,start[1]])
    let local=try await jar.localOwner();precondition(local=="200")
    let afterLocal=await ProbeFixture.shared.counts();precondition(afterLocal==afterWeb)
    do{_ = try await jar.current(credentials:.mobile);preconditionFailure("expired token passed")}
    catch let e as ServiceError{precondition(e.message.contains("synthetic rejected"))}
    let afterExpired=await ProbeFixture.shared.counts();_ = try await current(jar)
    let offline=try await jar.localOwner();precondition(offline=="200")
    let afterIndependent=await ProbeFixture.shared.counts();precondition(afterExpired==afterIndependent)
    try await jar.mergeArchive(archive("200","B-web","A-mobile"))
    do{_ = try await jar.current(credentials:.mobile);preconditionFailure("cross-owner token passed")}
    catch let e as ServiceError{precondition(e.message.contains("账号不匹配"))}
    try await jar.setMobileToken("B-mobile",for:"200")
    let accepted=try await current(jar);precondition(accepted.id=="200")
    let proof=try await jar.state().accounts.last?.credentialProof;precondition(proof == .init(web:true,mobile:true,ownerConfirmed:true))
    let beforeSame=await ProbeFixture.shared.counts()
    try await jar.mergeArchive(archive("200","B-web","B-mobile"));_ = try await current(jar)
    let afterSame=await ProbeFixture.shared.counts();precondition(beforeSame==afterSame)
    let exported=try await jar.archiveData();let exportedText=String(decoding:exported,as:UTF8.self)
    precondition(!exportedText.contains("credentialProof") && !exportedText.contains("ownerConfirmed"))
    // A mobile-only proof cannot turn an unverified Cookie into a usable web credential.
    let mobileJar=AccountJar();try await mobileJar.mergeArchive(archive("200","expired-web","B-only-mobile"))
    let tokenOnly=try await mobileJar.current(credentials:.mobile)!
    precondition(tokenOnly.id=="200" && tokenOnly.mobileToken=="B-only-mobile" && tokenOnly.header.isEmpty)
    let mobileLocal=try await mobileJar.localOwner();precondition(mobileLocal=="200")
    do{_ = try await current(mobileJar);preconditionFailure("mobile proof accepted an expired Cookie")}
    catch let e as ServiceError{precondition(e.message.contains("synthetic rejected"))}
    // Concurrent capability checks share each probe but retain each other's separate proof.
    let dualJar=AccountJar();try await dualJar.mergeArchive(archive("200","B-dual-web","B-dual-mobile"))
    let beforeDual=await ProbeFixture.shared.counts()
    try await withThrowingTaskGroup(of:Void.self){g in
      for i in 0..<16 {g.addTask{_ = try await dualJar.current(credentials:i%2==0 ? .web : .mobile)}}
      try await g.waitForAll()
    }
    let afterDual=await ProbeFixture.shared.counts();precondition(afterDual==[beforeDual[0]+1,beforeDual[1]+1])
    let dualProof=try await dualJar.state().accounts.last?.credentialProof
    precondition(dualProof == .init(web:true,mobile:true,ownerConfirmed:true))
    // A new same-UID session arriving during verification cannot inherit the previous response.
    try await jar.mergeArchive(archive("200","B-delayed",nil))
    let stale=Task{try await current(jar)}
    try await Task.sleep(nanoseconds:10_000_000)
    try await jar.mergeArchive(archive("200","B-replaced",nil))
    do{_ = try await stale.value;preconditionFailure("stale proof rewrote a new session")}
    catch let e as ServiceError{precondition(e.message.contains("登录信息已变更"))}
    let next=try await jar.state().accounts.last!;precondition(next.credentialProof?.web==false)
    let beforeConcurrent=await ProbeFixture.shared.counts()
    try await withThrowingTaskGroup(of:Void.self){g in
      for _ in 0..<8 {g.addTask{_ = try await current(jar)}}
      try await g.waitForAll()
    }
    let afterConcurrent=await ProbeFixture.shared.counts();precondition(afterConcurrent[0]-beforeConcurrent[0]==1)
    // A role change while checking an imported account must not return it for the new reader.
    try await jar.mergeArchive(archive("200","B-role-delayed",nil))
    let moved=Task{try await current(jar)}
    try await Task.sleep(nanoseconds:10_000_000);try await jar.select("100")
    do{_ = try await moved.value;preconditionFailure("role switch leaked prior account")}
    catch let e as ServiceError{precondition(e.message.contains("账号已切换"))}
    let cancelJar=AccountJar();try await cancelJar.mergeArchive(archive("200","B-cancel-web",nil))
    let cancelled=Task{try await current(cancelJar)}
    try await Task.sleep(nanoseconds:10_000_000);cancelled.cancel()
    do{_ = try await cancelled.value;preconditionFailure("cancelled verification persisted proof")}
    catch is CancellationError {}
    let cancelledProof=try await cancelJar.state().accounts.last?.credentialProof
    precondition(cancelledProof?.web==false && cancelledProof?.ownerConfirmed==false)
    // A verified login pair is published once and preserves explicit role assignment and metadata.
    try await jar.select("100");try await jar.assign(.video,choice:"100")
    let generation=try await jar.packStamp().generation
    let beforeSession=await ProbeFixture.shared.counts()
    try await jar.addSession(cookies("100","A-session"),token:"A-session-token",refresh:"session-refresh",device:"session-device",label:"")
    let savedSession=try await jar.state();let session=savedSession.accounts.first{$0.id=="100"}!
    let nextGeneration=try await jar.packStamp().generation
    precondition(nextGeneration==generation+1 && savedSession.owner(.role(.video))=="100" && savedSession.active=="100")
    precondition(session.label=="previous validated login" && session.mobileToken=="A-session-token" && session.archiveRefresh=="session-refresh" && session.archiveDevice=="session-device")
    precondition(session.credentialProof == .init(web:true,mobile:true,ownerConfirmed:true))
    _ = try await jar.current(credentials:.both)
    let afterSession=await ProbeFixture.shared.counts();precondition(beforeSession==afterSession)
    // A delayed legacy Cookie/manual-token login cannot replace a newer account decision either.
    let reviewedGeneration=try await jar.packStamp().generation
    try await jar.assign(.recommend,choice:"100")
    do{try await jar.setMobileToken("A-stale-manual",for:"100",expectedGeneration:reviewedGeneration);preconditionFailure("stale manual token replaced current authorization")}
    catch let e as ServiceError{precondition(e.message.contains("授权已变更"))}
    do{try await jar.add(cookies("100","A-stale-web"),label:"stale",expectedGeneration:reviewedGeneration);preconditionFailure("stale Cookie login replaced current session")}
    catch let e as ServiceError{precondition(e.message.contains("账号已变更"))}
    let afterStaleLogin=try await jar.state().accounts.first{$0.id=="100"}!
    precondition(afterStaleLogin.mobileToken=="A-session-token" && afterStaleLogin.label=="previous validated login")
    // Legacy Keychain data did not contain local proof; it retains the historical trusted state.
    let legacy=Data(#"{"accounts":[{"id":"100","label":"old","cookies":{"DedeUserID":"100","SESSDATA":"A-old","bili_jct":"old-csrf"}}],"active":"100"}"#.utf8)
    try await jar.fixtureLoad(JSONDecoder().decode(AccountJar.State.self,from:legacy))
    let beforeLegacy=await ProbeFixture.shared.counts();_ = try await current(jar)
    let legacyLocal=try await jar.localOwner();precondition(legacyLocal=="100")
    let afterLegacy=await ProbeFixture.shared.counts();precondition(beforeLegacy==afterLegacy)
    print("AccountJar integration: separate web/mobile proof, expired token permits web and offline owner, unconfirmed import denies files, token mismatch, concurrent proofs, cancellation, atomic login pair, replacement, role switch and legacy compatibility passed")
  }
}
'''
with tempfile.TemporaryDirectory(prefix="pili-account-import-") as tmp:
    d=Path(tmp);(d/"Accounts.swift").write_text(text);(d/"Fixture.swift").write_text(fixtures)
    sources=[s/(f+".swift") for f in ("Network/ServiceError","Network/ResponseCookieOrigin","Account/ImportedCredentialProof","Account/AccountRole","Account/AccountServices","Account/WebSessionCookies")]
    sources+=[n/"ArchiveKit/Sources/PiliArchive/ArchiveAccount.swift",d/"Accounts.swift",d/"Fixture.swift"]
    subprocess.run(["swiftc",*map(str,sources),"-o",str(d/"check")],check=True)
    subprocess.run([str(d/"check")],check=True)
