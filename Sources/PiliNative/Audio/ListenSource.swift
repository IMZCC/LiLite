import AVFoundation
import Foundation
import PiliWire

struct ListenMedia {
  let urls: [URL], reference: URL, kind: String
  let quality: Int?, codec: String?, bitrate: Int?
  var stream: DashStream? = nil, volume: AudioMeasurements? = nil, role: AccountRole = .main,
    grantOwner: String? = nil, preview: Bool = false
  var legacy: LegacyDURLPlan? = nil
  func authorize() async throws {
    guard (try await AccountJar.shared.localOwner(.role(role)) ?? "") == (grantOwner ?? "") else {
      throw ServiceError("播放账号已切换")
    }
  }
}
extension BiliAPI {
  func listeningMedia(_ t: ListenTrack, owner: String?, videoOwner: String?) async throws
    -> ListenMedia
  {
    let ref = URL(
      string: t.songID.map { "https://www.bilibili.com/audio/au\($0)" }
        ?? "https://www.bilibili.com/video/\(t.bvid)/")!
    if let ep = t.episode, let source = t.episodeSource {
      let info = try await playEpisodeInfo(ep, course: source.course, expectedAccount: videoOwner ?? "")
      let reference = URL(string: (source.course ? "https://www.bilibili.com/cheese/play/ep" : "https://www.bilibili.com/bangumi/play/ep") + String(ep.id))!
      guard let raw = info.dash, !raw.video.isEmpty else {
        let plan = LegacyDURLPlan(body: info.legacy, reference: reference, owner: videoOwner ?? "", preview: ep.preview || info.preview)
        return try ListenMedia.progressive(plan, kind: source.course ? "课程音轨" : "剧集音轨")
      }
      var media = raw.withLanguages(info.language, info.cur_language, volume: info.volume)
      media.isPreview = info.highQualityResolved ? false : (ep.preview || info.preview)
      guard let a = PlaybackOption.chooseAudio(media.audio ?? []), !a.routes(audio: true).isEmpty
      else { throw ServiceError("本集没有可用的音轨") }
      return .init(
        urls: a.routes(audio: true), reference: reference, kind: source.course ? "课程音轨" : "剧集音轨",
        quality: a.id, codec: a.codecs, bitrate: a.bandwidth, stream: a, volume: media.volume,
        role: .video, grantOwner: videoOwner, preview: media.isPreview)
    }
    guard let loc = t.locator else { throw ServiceError("无法识别这段音频") }
    let who = try await AccountJar.shared.current(.role(.main),credentials:.mobile)
    guard who?.id == owner else { throw ServiceError("账号已切换") }
    if who?.mobileToken?.isEmpty == false {
      do {
        let info = try await listener(for: owner).media(loc)
        switch info.info {
        case .playDash(let dash):
          let supported = dash.audio.filter { a in
            PlaybackOption.supportsAudio(
              .init(
                localID: Int(a.id), codec: a.codecs, rate: Int(a.bandwidth), width: nil,
                height: nil, initial: ""))
          }
          let prefs = NetworkMediaRules.current()
          let preferred = MediaNetwork.shared.cellular ? prefs.cellAudio : prefs.wifiAudio
          let stream =
            supported.first { $0.id == Int32(preferred) }
            ?? NetworkMediaRules.target(supported, target: NetworkMediaRules.audioRank(preferred)) {
              NetworkMediaRules.audioRank(Int($0.id))
            }
          if let stream {
            let urls = VODLine.current(
              ([stream.baseURL] + stream.backupURL).compactMap(httpsURL), audio: true)
            if !urls.isEmpty {
              return .init(
                urls: urls, reference: ref, kind: "DASH 音频", quality: Int(stream.id),
                codec: stream.codecs, bitrate: Int(stream.bandwidth),
                stream: .init(listener: stream),
                volume: info.hasVolume ? .init(listener: info.volume) : nil, grantOwner: owner)
            }
          }
        case .playURL(let media):
          if let first = media.durl.first {
            let urls = VODLine.current(
              ([first.url] + first.backupURL).compactMap(httpsURL), audio: true)
            if !urls.isEmpty {
              return .init(
                urls: urls, reference: ref, kind: "音频文件", quality: Int(info.qn), codec: nil,
                bitrate: nil, grantOwner: owner)
            }
          }
        case nil: break
        }
        throw ServiceError("未提供设备支持的音轨")
      }
    }
    try Task.checkCancellation()
    // The same publicly available song/video fallback as the song and video detail pages.
    // Their servers still determine entitlement under the assigned account.
    if let song = t.songID {
      struct Source: Decodable { let cdns: [String]?, type: Int? }
      let s = try await read(
        "/audio/music-service-c/web/url", ["sid": String(song), "privilege": "2", "quality": "2"],
        host: "www.bilibili.com", expectedAccount: owner ?? "", as: Source.self)
      let urls = VODLine.current((s.cdns ?? []).compactMap(httpsURL), audio: true)
      guard !urls.isEmpty else { throw ServiceError("没有可播放的音频") }
      return .init(
        urls: urls, reference: ref, kind: "音频投稿", quality: s.type, codec: nil, bitrate: nil,
        grantOwner: owner)
    }
    let f: DashFormats
    do { f = try await formats(t.bvid, cid: t.cid, expectedAccount: videoOwner ?? "") }
    catch let e as ServiceError where e.message == "这个视频没有分轨播放地址" {
      return try ListenMedia.progressive(await legacyPlayback(t.bvid, cid: t.cid, expectedAccount: videoOwner ?? ""), kind: "视频音轨")
    }
    guard let audio = PlaybackOption.chooseAudio(f.audio ?? []), !audio.routes(audio: true).isEmpty
    else { throw ServiceError("没有可用的音轨") }
    return .init(
      urls: audio.routes(audio: true), reference: ref, kind: "视频音轨", quality: audio.id,
      codec: audio.codecs, bitrate: audio.bandwidth, stream: audio, volume: f.volume, role: .video,
      grantOwner: videoOwner, preview: f.isPreview)
  }
}
extension ListenMedia {
  static func progressive(_ plan: LegacyDURLPlan, kind: String) throws -> Self {
    guard let first = try plan.body.parts.first else { throw ServiceError("没有可用的音轨") }
    return .init(urls: first.routes, reference: plan.reference, kind: kind, quality: plan.body.quality,
      codec: nil, bitrate: nil, volume: plan.body.volume, role: .video, grantOwner: plan.owner,
      preview: plan.preview, legacy: plan)
  }
}

extension DashStream {
  init(listener s: PiliBilibiliAppListenerV1_DashItem) {
    id = Int(s.id)
    codecs = s.codecs
    bandwidth = Int(s.bandwidth)
    width = nil
    height = nil
    frameRate = nil
    baseUrl = s.baseURL
    backupUrl = s.backupURL
    SegmentBase = .init(initial: s.segmentBase.initialization, index: s.segmentBase.indexRange)
  }
}
extension AudioMeasurements {
  init(listener v: PiliBilibiliAppPlayurlV1_VolumeInfo) {
    measured_i = v.measuredI
    measured_lra = v.measuredLra
    measured_tp = v.measuredTp
    measured_threshold = v.measuredThreshold
    target_i = v.targetI
    target_tp = v.targetTp
    target_offset = v.targetOffset
  }
}
