import Foundation

extension BiliAPI {
  func playEpisodeService(
    _ e: SeasonInfo.Episode, course: Bool, language: String?, expectedAccount: String?
  ) async throws -> (DashFormats, [EpisodeClip]) {
    let info = try await playEpisodeInfo(e, course: course, language: language, expectedAccount: expectedAccount)
    guard let dash = info.dash, !dash.video.isEmpty else { throw ServiceError("没有可用的分轨视频流") }
    var formats = dash.withLanguages(info.language, info.cur_language, volume: info.volume)
    formats.isPreview = e.preview || info.preview
    return (formats, info.clips)
  }
  func playEpisodeInfo(_ e: SeasonInfo.Episode, course: Bool, language: String? = nil,
    expectedAccount: String?, quality: Int = 129) async throws -> EpisodePlayPayload.Info {
    guard e.canRequestPlayback else { throw ServiceError("此分集暂不可播放") }
    let user: String
    if let expectedAccount {
      user = expectedAccount
    } else {
      user = try await AccountJar.shared.current(.role(.video))?.id ?? ""
    }
    func request(_ quality: Int) async throws -> EpisodePlayPayload.Info {
      let reply = try await episodePlayBody(e, course: course, language: language, owner: user, quality: quality)
      let envelope = try EpisodePlayPayload(reply.data, legacy: reply.legacy)
      var info: EpisodePlayPayload.Info
      switch envelope.route {
      case .play(let value): info = value
      case .unavailable(let reason): throw ServiceError(reason)
      }
      info.preview = info.preview || reply.preview
      guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == user else { throw ServiceError("视频账号已切换") }
      return info
    }
    var info = try await request(quality)
    if let dash = info.dash, let missing = dash.missingBelowHighest((info.support_formats ?? []).map(\.quality)) {
      do {
        let extra = try await request(missing)
        if extra.preview == info.preview, extra.cur_language == info.cur_language, let added = extra.dash { info.dash = dash.mergingVideo(added) }
      } catch { try Task.checkCancellation() }
    }
    guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == user else { throw ServiceError("视频账号已切换") }
    return info
  }
  func episodePlayBody(_ e: SeasonInfo.Episode, course: Bool, language: String?, owner: String, quality: Int = 127)
    async throws -> (data: Data, legacy: Bool, preview: Bool)
  {
    var fields = [
      "ep_id": String(e.id), "cid": String(e.cid), "qn": String(quality), "fnval": "4048", "fnver": "0",
      "fourk": "1", "biz_type": course ? "pugv" : "ogv", "scene": "normal",
      "from_client": "BROWSER", "drm_tech_type": "0", "app_id": "100",
      "voice_balance": AudioFilterChoice.requestsProcessing ? "1" : "0",
    ]
    if let a = e.aid { fields["avid"] = String(a) }
    if !e.bvid.isEmpty { fields["bvid"] = e.bvid }
    fields["cur_language"] = language
    func webFallback(preview: Bool = false) async throws -> (data: Data, legacy: Bool, preview: Bool) {
      try Task.checkCancellation()
      guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == owner else { throw ServiceError("视频账号已切换") }
      var legacy = fields; legacy["biz_type"] = nil
      let data = try await fetch(
        course ? "/pugv/player/web/playurl" : "/pgc/player/web/v2/playurl", try await sign(legacy),
        host: "api.bilibili.com", expectedAccount: owner)
      return (data, true, preview)
    }
    let body: Data
    do {
      body = try await fetch(
        "/ogv/player/playview", try await sign(fields), host: "api.bilibili.com",
        expectedAccount: owner)
    } catch let err as URLError where err.code == .timedOut || err.code == .networkConnectionLost {
      return try await webFallback()
    }
    if EpisodePlayPayload.requestsWebFallback(body) { return try await webFallback(preview: EpisodePlayPayload.preview(body)) }
    return (body, false, false)
  }
}
