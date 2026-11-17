import SwiftUI

extension BiliAPI {
  struct AuthorizedEpisode {
    let formats: DashFormats?, owner: String, seriesKey: String?, title: String?, order: Int?,
      seconds: Int?, clips: [EpisodeClip]
    var uploader: String? = nil
    var legacy: LegacyDURLBody? = nil
    var qualities: [Int] {
      if let formats { return Set(formats.video.filter(PlaybackOption.supportsOfflineVideo).map(\.id)).sorted(by: >) }
      guard let legacy else { return [] }
      return Set((legacy.accept_quality ?? []) + [legacy.quality ?? 0]).filter { $0 > 0 }.sorted(by: >)
    }
  }
  /// Read entitlement metadata and media using the exact same selected playback account, including an explicit guest selection.
  func cacheEpisode(_ ep: EpisodeResource, cid: Int64, bvid: String, owner: String, quality: Int = 127) async throws
    -> AuthorizedEpisode
  {
    typealias Map = EpisodeCachePolicy.Map
    func data(_ path: String, _ fields: [String: String]) async throws -> Map {
      let raw = try await fetch(
        path, fields, host: "api.bilibili.com", expectedAccount: owner, cacheVideoIdentity: true)
      guard let r = try JSONSerialization.jsonObject(with: raw) as? Map else {
        throw ServiceError("无法读取剧集信息")
      }
      guard r["code"] as? Int == 0 else { throw ServiceError(r["message"] as? String ?? "剧集服务不可用") }
      guard let payload = r["result"] as? Map ?? r["data"] as? Map else {
        throw ServiceError("没有返回这一集的信息")
      }
      return payload
    }
    let metadata = try await data(
      ep.course ? "/pugv/view/web/season" : "/pgc/view/web/season", ["ep_id": String(ep.id)])
    let episodes =
      (metadata["episodes"] as? [Map] ?? [])
      + (metadata["section"] as? [Map] ?? []).flatMap { $0["episodes"] as? [Map] ?? [] }
    guard
      let row = episodes.first(where: {
        EpisodeCachePolicy.episodeID($0, course: ep.course) == ep.id
          && ($0["cid"] as? NSNumber)?.int64Value == cid
      })
    else { throw ServiceError("分集或视频源已更新，请重新选择") }
    let seriesRights = metadata["rights"] as? Map
    let episodeRights = row["rights"] as? Map
    var vip = false
    if !owner.isEmpty
      && [seriesRights, episodeRights].contains(where: {
        EpisodeCachePolicy.flag($0?["only_vip_download"]) == true
      })
    {
      let user = try await data("/x/web-interface/nav", [:])
      vip = (user["vipStatus"] as? NSNumber)?.intValue == 1
    }
    try EpisodeCachePolicy.allow(series: metadata, episode: row, vip: vip)
    var item = try JSONDecoder().decode(
      SeasonInfo.Episode.self, from: JSONSerialization.data(withJSONObject: row))
    item.id = ep.id
    guard item.canRequestPlayback, !item.preview,
      item.bvid.isEmpty || bvid.isEmpty || item.bvid == bvid
    else { throw ServiceError("分集信息已更新，请重新选择") }
    let response = try await episodePlayBody(item, course: ep.course, language: nil, owner: owner, quality: quality)
    guard !response.preview else { throw ServiceError("试看内容不支持离线缓存") }
    let grant = try EpisodePlayPayload(response.data, legacy: response.legacy)
    switch grant.route {
    case .unavailable(let message): throw ServiceError(message)
    case .play(let info): guard !info.preview else { throw ServiceError("试看内容不支持离线缓存") }
    }
    guard let raw = try JSONSerialization.jsonObject(with: response.data) as? Map,
      let media = raw["data"] as? Map ?? raw["result"] as? Map
    else { throw ServiceError("未能读取分集缓存授权") }
    let clear = try EpisodeCachePolicy.clearPayload(media)
    var formats = try (clear["dash"] as? Map).map { try JSONDecoder().decode(
      DashFormats.self, from: JSONSerialization.data(withJSONObject: $0)) }
    if formats?.video.isEmpty == true { formats = nil }
    let legacy = formats == nil ? try JSONDecoder().decode(LegacyDURLBody.self, from: JSONSerialization.data(withJSONObject: clear)) : nil
    if let legacy { _ = try legacy.parts }
    let info = media["video_info"] as? Map ?? media
    if let v = (info["volume"] ?? media["volume"]) as? Map {
      formats?.volume = try? JSONDecoder().decode(
        AudioMeasurements.self, from: JSONSerialization.data(withJSONObject: v))
    }
    let clips = (info["clip_info_list"] as? [Map] ?? []).compactMap { row in
      try? JSONDecoder().decode(EpisodeClip.self, from: JSONSerialization.data(withJSONObject: row))
    }.filter(\.usable)
    let duration = (row["duration"] as? NSNumber)?.doubleValue
    let seconds = duration.flatMap { v in
      v > 0 && v.isFinite ? Int(exactly: (ep.course ? v : v / 1000).rounded()) : nil
    }
    return .init(
      formats: formats, owner: owner,
      seriesKey: (metadata["season_id"] as? NSNumber).map {
        (ep.course ? "course:" : "season:") + $0.stringValue
      }, title: metadata["title"] as? String,
      order: (row["index"] as? NSNumber)?.intValue
        ?? episodes.firstIndex(where: {
          EpisodeCachePolicy.episodeID($0, course: ep.course) == ep.id
        }).map {
          $0 + 1
        }, seconds: seconds, clips: clips,
      uploader: (metadata["up_info"] as? Map)?["uname"] as? String, legacy: legacy)
  }
}
struct EpisodeCacheView: View {
  let episode: SeasonInfo.Episode, course: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var qualities: [Int] = []
  @State private var audioChoices: [Int] = []
  @State private var audio = 0
  @State private var owner: String?
  @State private var q = 0
  @State private var extras = true
  @State private var busy = false
  @State private var issue: String?
  @State private var revision = 0
  var body: some View {
    Form {
      Text(episode.label)
      if let issue {
        Text(issue).foregroundStyle(.secondary)
        Button("重试") { revision += 1 }
      } else if owner == nil {
        ProgressView()
      } else {
        Picker("画质", selection: $q) {
          Text(OfflineQuality.video(qualities).map { "默认 · " + StreamQuality.name($0) } ?? "默认").tag(0)
          ForEach(qualities, id: \.self) { x in Text(StreamQuality.name(x)).tag(x) }
        }
        if !audioChoices.isEmpty {
          Picker("音质", selection: $audio) {
            Text(OfflineQuality.audio(audioChoices).map { "默认 · " + PlaybackOption.audioName($0) } ?? "默认").tag(0)
            ForEach(audioChoices, id: \.self) { x in Text(PlaybackOption.audioName(x)).tag(x) }
          }
        }
        Toggle("同时缓存字幕和弹幕", isOn: $extras)
        Button("开始缓存") { Task { await add() } }.disabled(busy)
      }
    }.navigationTitle("缓存本集").task(id: revision) {
      issue = nil
      owner = nil
      do {
        let uid = try await AccountJar.shared.current(.role(.video))?.id ?? ""
        let plan = try await BiliAPI.shared.cacheEpisode(
          .init(id: episode.id, course: course), cid: episode.cid, bvid: episode.bvid, owner: uid)
        try Task.checkCancellation()
        qualities = plan.qualities
        guard !qualities.isEmpty else { throw ServiceError("没有可缓存的画质") }
        audioChoices = Set(
          (plan.formats?.audio ?? []).filter(PlaybackOption.supportsAudio).map(\.id)
        ).sorted(by: >)
        audio = 0
        q = 0
        owner = uid
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
  @MainActor private func add() async {
    guard !busy, let owner else { return }
    busy = true
    defer { busy = false }
    do {
      guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == owner else {
        throw ServiceError("视频账号已切换")
      }
      var v = OfflineVideo(
        bvid: episode.bvid, cid: episode.cid, title: episode.label, part: episode.label)
      v.episode = .init(id: episode.id, course: course)
      v.cacheOwner = owner; v.scoped = true; v.cover = episode.cover
      v.quality = q == 0 ? nil : q
      v.audioQuality = audio == 0 ? nil : audio
      v.aid = episode.aid
      v.includeExtras = extras
      await Downloads.shared.start(v)
      guard let row = Downloads.shared.existing(v, owner: owner) else {
        throw ServiceError(Downloads.shared.issue ?? "无法添加缓存")
      }
      if row.phase == .failed { throw ServiceError(row.error ?? "缓存未开始") }
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
