import Foundation

private actor ProbeCounter {
  var probes = 0, sent = 0
  func resolve(_ uid:String,delay:UInt64=60_000_000) async throws -> String {
    probes += 1; try await Task.sleep(nanoseconds:delay);return uid
  }
  func didSend(){sent += 1}
  func counts()->(Int,Int){(probes,sent)}
}

@main enum ImportedCredentialCheck {
  static func main() async throws {
    let old = ImportedCredentialProof.restored(previous:nil,sameWeb:true,sameMobile:true)
    precondition(!old.requiresValidation)
    precondition(ImportedCredentialProof.restored(previous:nil,sameWeb:false,sameMobile:false) == .init(web:false,mobile:false,ownerConfirmed:false))
    precondition(ImportedCredentialProof.restored(previous:.init(web:false,mobile:true),sameWeb:true,sameMobile:true) == .init(web:false,mobile:true,ownerConfirmed:false))
    precondition(ImportedCredentialProof.restored(previous:old,sameWeb:true,sameMobile:false) == .init(web:true,mobile:false,ownerConfirmed:false))
    precondition(ImportedCredentialProof.restored(previous:old,sameWeb:false,sameMobile:true) == .init(web:false,mobile:true,ownerConfirmed:false))
    let freshWithoutMobile = ImportedCredentialProof.restored(previous:nil,sameWeb:false,sameMobile:true)
    precondition(!freshWithoutMobile.permitsLocal(hasMobile:false))
    precondition(ImportedCredentialProof(web:false,mobile:true).permitsLocal(hasMobile:true))
    precondition(!ImportedCredentialProof(web:false,mobile:true).permitsLocal(hasMobile:false))
    precondition(ImportedCredentialProof.restored(previous:nil,sameWeb:false,sameMobile:false,knownOwner:true).permitsLocal(hasMobile:true))
    let check = ImportedCredentialChecks(), counter = ProbeCounter()
    let request = ImportedCredentialChecks.Request(owner:"200",web:true,material:"synthetic-web")
    try await withThrowingTaskGroup(of:Void.self){group in
      for _ in 0..<8 {group.addTask {
        try await check.validate(request){try await counter.resolve("200")}
        await counter.didSend()
      }}
      try await group.waitForAll()
    }
    let shared = await counter.counts();precondition(shared.0==1 && shared.1==8)
    let wrong = ImportedCredentialChecks.Request(owner:"200",web:false,material:"synthetic-mobile-A")
    do {
      try await check.validate(wrong){try await counter.resolve("100")}
      throw ServiceError("A different token owner was accepted")
    } catch let error as ServiceError {precondition(error.message.contains("账号不匹配"))}
    let afterWrong=await counter.counts();precondition(afterWrong.1==8)
    let cancel = Task {
      try await check.validate(.init(owner:"200",web:true,material:"cancel-synthetic")){try await counter.resolve("200")}
      await counter.didSend()
    }
    try await Task.sleep(nanoseconds:10_000_000);cancel.cancel()
    do {try await cancel.value;preconditionFailure("cancelled first use was allowed")}
    catch is CancellationError {}
    let afterCancel=await counter.counts();precondition(afterCancel.1==8)
    // Web and mobile credentials cannot satisfy each other's checks, even with identical fixture bytes.
    async let web:Void = check.validate(.init(owner:"200",web:true,material:"dual-fixture")){try await counter.resolve("200")}
    async let mobile:Void = check.validate(.init(owner:"200",web:false,material:"dual-fixture")){try await counter.resolve("200")}
    try await web;try await mobile
    let final=await counter.counts();precondition(final.0==5)
    print("Imported credentials: trusted local compatibility, changed material requires its own proof, concurrent first use shares one probe, mismatched owner and cancellation stop sends")
  }
}
