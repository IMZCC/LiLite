import SwiftUI

/// These are sibling regions of a single stable player; rotation never presents a second AVPlayer.
struct TheaterWorkspace<Picture: View, Panel: View>: View {
  let open: Bool
  @ViewBuilder let picture: () -> Picture
  @ViewBuilder let panel: () -> Panel
  var body: some View {
    GeometryReader { frame in
      let size = frame.size
      let wide = size.width > size.height
      let flow = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
      let panelWidth = min(500, size.width * 0.5)
      let panelHeight = size.height * 0.62
      flow {
        picture()
          .frame(width: wide && open ? size.width - panelWidth : size.width,
                 height: !wide && open ? size.height - panelHeight : size.height)
          .clipped()
        if open {
          panel()
            .frame(width: wide ? panelWidth : size.width, height: wide ? size.height : panelHeight)
            .background(.background).clipped()
        }
      }
    }
  }
}

struct TheaterSubject {
  let cid: Int64, oid: Int64?, type: Int
  var bvid: String? = nil, aid: Int64? = nil, creator: Int64? = nil
  var introduction: String? = nil, interactive = false, comments = true,shortcutCanFollow=true
}

struct TheaterTools: View {
  @ObservedObject var model: PlayerModel
  let subject: TheaterSubject?, playlist: AnyView?, close: () -> Void
  var bulletSnapshot:(()->[Bullet])?=nil
  @AppStorage("detail.chapters") private var chapters = true
  @AppStorage("sponsor.enabled") private var sponsor = false
  @AppStorage(SpeedPresets.key) private var speeds = Data()
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Text("播放面板").font(.headline)
        Spacer()
        Button(action: close) { Image(systemName: "xmark.circle.fill").font(.title2) }
          .accessibilityLabel("关闭播放面板")
      }.padding(.horizontal).padding(.vertical, 4)
      Divider()
      PiliNavigationStack {
        List {
          if let playlist { NavigationLink("选集") { playlist.modifier(ReplyEdgeDismiss()).navigationTitle("选集") } }
          if let s = subject {
            if let id = s.oid, id > 0, s.comments {
              NavigationLink("评论") {
                Discussion(oid: id, type: s.type, owner: s.creator, intro: s.introduction)
                  .environment(\.replyPlayback, ReplyPlaybackTarget(duration: model.duration, seek: model.seek, model: model))
                  .id("\(s.type):\(id)")
              }
            }
            if let aid = s.aid, s.type == 1, s.bvid != nil {
              NavigationLink("视频笔记") { ArchiveNotes(aid: aid, interactive: s.interactive, model: model, cid: s.cid, videoTitle: nil) }
            }
            if chapters, let bv = s.bvid {
              NavigationLink("视频章节") { ArchiveChapterPanel(model:model,bvid:bv,cid:s.cid) }
            }
            if s.cid > 0 {
              NavigationLink("弹幕列表") {
                DanmakuList(cid: s.cid, aid: s.aid, duration: model.duration, current: model.seconds, seek: model.seek,snapshot:bulletSnapshot)
                  .id(s.cid)
              }
            }
            if sponsor && s.bvid != nil {
              NavigationLink("空降标记") { SponsorList(model: model, inlineEditor: true) }
            }
          }
          Section("播放") {
            ArchiveSourceTools(model:model)
            ArchiveTrendToggle(timeline:model.timeline)
            NavigationLink("视频解码"){DecoderSettings()}
            if !model.availableQualities.isEmpty {
              Menu("画质") {
                ForEach(model.availableQualities, id: \.self) { quality in
                  Button(StreamQuality.name(quality)) { Task { await model.changeQuality(quality, manualVideo: true) } }
                }
              }.disabled(model.switching)
            }
            if !model.audioChoices.isEmpty {
              Menu("音质") {
                ForEach(model.audioChoices, id: \.self) { id in
                  Button(PlaybackOption.audioName(id)) {
                    Task { await model.changeQuality(model.availableQualities.contains(model.quality) ? model.quality : model.availableQualities.first ?? 0, manualAudio: id) }
                  }
                }
              }.disabled(model.switching)
            }
            if let issue = model.qualityError { Text(issue).foregroundStyle(.secondary) }
            Menu("播放速度") {
              ForEach(SpeedPresets.decode(speeds), id: \.self) { speed in
                Button("\(speed.formatted())×") { model.rate = Float(speed); if model.playing { model.engine.rate = Float(speed) } }
              }
            }
            NavigationLink("定时停止") { SleepTimerForm(live: false) }
            NavigationLink("播放器音量") { AudioLevelSettings() }
            PlaybackTrackSwitch(player: model.engine)
            NavigationLink("播放器内核") { PlaybackEngineSettings() }
            RepeatPicker(session: model.preferences)
            SubtitlePicker(model: model)
            SpokenTrackPicker(model: model)
          }
          Section("弹幕") {
            Toggle("显示弹幕", isOn: model.preferences.binding(\.bullets))
            NavigationLink("弹幕样式与过滤") { DanmakuStylePanel() }
          }
        }.navigationTitle("播放工具").navigationBarTitleDisplayMode(.inline)
      }
    }
  }
}
