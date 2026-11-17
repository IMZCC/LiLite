import Foundation

// /x/tv/playurl uses the same published AppSign algorithm and public client identity as login.
enum CastProjectionSigning {
  static func signed(_ input: [String: String]) throws -> [String: String] {
    var params = input
    params["actionKey"] = "appkey"
    return MobileClientSigning.signed(params)
  }
}
extension BiliAPI {
  func castSource(_ subject: CastSubject, owner: String) async throws -> PlaybackSource {
    guard subject.valid, let ref = subject.reference else { throw CastProblem.denied }
    let identity = try await AccountJar.shared.current(.role(.video),credentials:.mobile)
    guard (identity?.id ?? "") == owner else { throw CastProblem.stale }
    let f = try CastProjectionSigning.signed(subject.fields(token: identity?.mobileToken))
    let p: ArchiveGrantResponse<CastGrantBody>
    do {
      p = try await read(
        "/x/tv/playurl", f, expectedAccount: owner, as: ArchiveGrantResponse<CastGrantBody>.self)
    } catch let e as ServiceError { throw ServiceError("电视投屏服务：" + e.localizedDescription) }
    try Task.checkCancellation()
    let fresh = try await AccountJar.shared.current(.role(.video),credentials:.mobile)
    guard (fresh?.id ?? "") == owner, fresh?.mobileToken == identity?.mobileToken else {
      throw CastProblem.stale
    }
    let urls = VODLine.current(try p.body.routes(guest: owner.isEmpty, grant: p.grant))
    guard let url = urls.first else { throw CastProblem.denied }
    return PlaybackSource(
      url: url, backups: Array(urls.dropFirst()), quality: p.body.quality ?? subject.quality,
      reference: ref)
  }
}
