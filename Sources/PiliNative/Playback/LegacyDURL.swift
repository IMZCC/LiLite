import Foundation

extension BiliAPI {
  func legacyPlayback(_ bvid: String, cid: Int64, quality: Int = 127, language: String? = nil,
    expectedAccount: String, forCache: Bool = false, preferMP4: Bool = false) async throws -> LegacyDURLPlan {
    guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == expectedAccount else { throw ServiceError("视频账号已切换") }
    var fields = ["bvid": bvid, "cid": String(cid), "qn": String(quality), "fnval": preferMP4 ? "1" : "4048", "fnver": "0", "fourk": "1",
      "voice_balance": AudioFilterChoice.requestsProcessing ? "1" : "0"]
    fields["cur_language"] = language
    if preferMP4 { fields["platform"] = "html5" }
    let result = try await read("/x/player/wbi/playurl", try await sign(fields), expectedAccount: expectedAccount,
      as: ArchiveGrantResponse<LegacyDURLBody>.self)
    guard !result.grant.protected, !forCache || result.grant.permitsCache,
      result.grant.permits(result.body.quality ?? 0, guest: expectedAccount.isEmpty),
      let reference = URL(string: "https://www.bilibili.com/video/\(bvid)/") else { throw ServiceError("当前账号没有可播放的视频") }
    let body = result.body
    _ = try body.parts
    let allowed = body.accept_quality?.filter { result.grant.permits($0, guest: expectedAccount.isEmpty) }
    return .init(body: .init(durl: body.durl, quality: body.quality, accept_quality: allowed,
      language: body.language, cur_language: body.cur_language, volume: body.volume), reference: reference,
      owner: expectedAccount, preview: result.grant.preview)
  }
}
