import SwiftUI

struct SeasonBatchCache: View {
  let episodes: [SeasonInfo.Episode], course: Bool, title: String
  @EnvironmentObject private var accounts: AccountContext
  @State private var selection = Set<Int64>()
  @State private var receipt = [Int64: String]()
  @State private var busy = false
  @State private var extras = true
  @State private var quality = 0
  @State private var audio = 0
  @State private var videoChoices: [Int] = []
  @State private var audioChoices: [Int] = []
  @State private var fetching = false
  @State private var menuIssue: String?
  private var available: [SeasonInfo.Episode] { episodes.filter(\.allowCacheEntry) }
  private var uid: String { accounts.state.owner(.role(.video)) ?? "" }
  var body: some View {
    List {
      Section {
        Text(title).piliFont(.headline)
        Button(selection.count == available.count ? "取消全选" : "全选") {
          selection = selection.count == available.count ? [] : Set(available.map(\.id))
        }
        Button(fetching ? "正在读取可缓存音画质…" : "读取所选分集的音画质") {
          let viewer = uid; Task { await fetchOptions(viewer) }
        }.disabled(selection.isEmpty || fetching)
        if !videoChoices.isEmpty {
          Picker("画质", selection: $quality) {
            Text(OfflineQuality.video(videoChoices).map { "默认 · " + StreamQuality.name($0) } ?? "默认").tag(0);
            ForEach(videoChoices, id: \.self) { Text(StreamQuality.name($0)).tag($0) }
          }
        }
        if !audioChoices.isEmpty {
          Picker("音质", selection: $audio) {
            Text(OfflineQuality.audio(audioChoices).map { "默认 · " + PlaybackOption.audioName($0) } ?? "默认").tag(0);
            ForEach(audioChoices, id: \.self) { Text(PlaybackOption.audioName($0)).tag($0) }
          }
        }
        if let menuIssue { Text(menuIssue).font(.caption).foregroundStyle(.secondary) }
        Toggle("同时缓存字幕和弹幕", isOn: $extras)
        NavigationLink("查看缓存") { DownloadsView() }
      }
      ForEach(available) { e in
        Button {
          if !selection.insert(e.id).inserted { selection.remove(e.id) }
        } label: {
          VStack(alignment: .leading) {
            Label(
              e.label, systemImage: selection.contains(e.id) ? "checkmark.circle.fill" : "circle")
            if let r = receipt[e.id] { Text(r).piliFont(.caption).foregroundStyle(.secondary) }
          }
        }
      }
      Button("缓存所选 \(selection.count) 集") {
        let owner = uid
        Task { await run(owner) }
      }.disabled(selection.isEmpty)
    }.disabled(busy).navigationTitle("选择缓存").onChange(of: uid) { _, _ in
      selection = []
      receipt = [:]; videoChoices = []; audioChoices = []; quality = 0; audio = 0; menuIssue = nil
    }
  }
  @MainActor private func fetchOptions(_ owner: String) async {
    guard !fetching, let e = available.first(where: { selection.contains($0.id) }) else { return }
    fetching = true; defer { fetching = false }
    do {
      let plan = try await BiliAPI.shared.cacheEpisode(
        .init(id: e.id, course: course), cid: e.cid, bvid: e.bvid, owner: owner);
      try Task.checkCancellation(); guard uid == owner else { return }
      videoChoices = plan.qualities
      audioChoices = Set((plan.formats?.audio ?? []).filter(PlaybackOption.supportsAudio).map(\.id))
        .sorted(by: >)
      if !videoChoices.contains(quality) { quality = 0 };
      if !audioChoices.contains(audio) { audio = 0 }; menuIssue = nil
    } catch { if !Task.isCancelled && uid == owner { menuIssue = error.localizedDescription } }
  }
  @MainActor private func run(_ owner: String) async {
    guard !busy, owner == uid else { return }
    busy = true
    defer { busy = false }
    let rows = available.filter { selection.contains($0.id) }
    for e in rows {
      guard !Task.isCancelled, uid == owner else { return }
      var v = OfflineVideo(bvid: e.bvid, cid: e.cid, title: title, part: e.label)
      v.episode = .init(id: e.id, course: course)
      v.cacheOwner = owner; v.scoped = true; v.cover = e.cover
      v.quality = quality == 0 ? nil : quality; v.audioQuality = audio == 0 ? nil : audio
      v.includeExtras = extras
      v.aid = e.aid
      if let row = Downloads.shared.existing(v, owner: owner), row.phase != .failed {
        receipt[e.id] = "已在缓存列表"
        selection.remove(e.id)
        continue
      }
      // Downloads resolves a fresh entitlement and clear media plan per episode under the selected playback account.
      await Downloads.shared.start(v)
      guard !Task.isCancelled, uid == owner else { return }
      if let row = Downloads.shared.existing(v, owner: owner), row.phase != .failed {
        receipt[e.id] = "已加入缓存"
        selection.remove(e.id)
      } else {
        receipt[e.id] =
          Downloads.shared.existing(v, owner: owner)?.error ?? Downloads.shared.issue
          ?? "未能缓存"
      }
    }
  }
}
