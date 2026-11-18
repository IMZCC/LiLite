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
      // Same icon rows as the inline 更多 sheet (the original shows one sheet in both modes).
      PiliNavigationStack {
        List {
          Section {
            if let playlist {
              NavigationLink { playlist.modifier(ReplyEdgeDismiss()).navigationTitle("选集") } label: { row("list.number", "选集") }
            }
            if let s = subject {
              if let id = s.oid, id > 0, s.comments {
                NavigationLink {
                  Discussion(oid: id, type: s.type, owner: s.creator, intro: s.introduction)
                    .environment(\.replyPlayback, ReplyPlaybackTarget(duration: model.duration, seek: model.seek, model: model))
                    .id("\(s.type):\(id)")
                } label: { row("text.bubble", "评论") }
              }
              if let aid = s.aid, s.type == 1, s.bvid != nil {
                NavigationLink { ArchiveNotes(aid: aid, interactive: s.interactive, model: model, cid: s.cid, videoTitle: nil) }
                  label: { row("note.text", "查看笔记") }
              }
              if chapters, let bv = s.bvid {
                NavigationLink { ArchiveChapterPanel(model:model,bvid:bv,cid:s.cid) } label: { row("list.bullet.rectangle", "分段") }
              }
            }
            NavigationLink { SleepTimerForm(live: false) } label: { row("hourglass", "定时关闭") }
            NavigationLink { AudioLevelSettings() } label: { row("speaker.wave.2", "播放器音量") }
            ArchiveSourceTools(model:model)
            ArchiveTrendToggle(timeline:model.timeline)
            PlaybackTrackSwitch(player: model.engine)
          }
          Section {
            if !model.availableQualities.isEmpty {
              Menu {
                ForEach(model.availableQualities, id: \.self) { quality in
                  Button(StreamQuality.name(quality)) { Task { await model.changeQuality(quality, manualVideo: true) } }
                }
              } label: { row("play.circle", "选择画质", "当前画质 " + StreamQuality.name(model.quality)) }
              .disabled(model.switching)
            }
            if !model.audioChoices.isEmpty {
              Menu {
                ForEach(model.audioChoices, id: \.self) { id in
                  Button(PlaybackOption.audioName(id)) {
                    Task { await model.changeQuality(model.availableQualities.contains(model.quality) ? model.quality : model.availableQualities.first ?? 0, manualAudio: id) }
                  }
                }
              } label: { row("opticaldisc", "选择音质") }.disabled(model.switching)
            }
            if let issue = model.qualityError { Text(issue).font(.footnote).foregroundStyle(.secondary) }
            NavigationLink { DecoderSettings() } label: { row("av.remote", "解码格式") }
            NavigationLink { PlaybackEngineSettings() } label: { row("cpu", "播放器内核") }
            Menu {
              ForEach(SpeedPresets.decode(speeds), id: \.self) { speed in
                Button("\(speed.formatted())×") { model.rate = Float(speed); if model.playing { model.engine.rate = Float(speed) } }
              }
            } label: { row("gauge.with.needle", "播放速度", Double(model.rate).formatted() + "×") }
            Menu { RepeatPicker(session: model.preferences) } label: { row("repeat", "播放顺序") }
          }
          Section {
            if let s = subject, s.cid > 0 {
              NavigationLink {
                DanmakuList(cid: s.cid, aid: s.aid, duration: model.duration, current: model.seconds, seek: model.seek,snapshot:bulletSnapshot)
                  .id(s.cid)
              } label: { row("list.bullet", "弹幕列表") }
            }
            Toggle(isOn: model.preferences.binding(\.bullets)) { row("text.bubble.fill", "显示弹幕") }
            NavigationLink { DanmakuStylePanel() } label: { row("text.bubble.badge.gearshape", "弹幕设置") }
            SubtitlePicker(model: model)
            SpokenTrackPicker(model: model)
            if sponsor, subject?.bvid != nil {
              NavigationLink { SponsorList(model: model, inlineEditor: true) } label: { row("forward.end", "空降标记") }
            }
          }
        }
        .listStyle(.insetGrouped).listSectionSpacing(12)
        .navigationTitle("更多").navigationBarTitleDisplayMode(.inline)
      }
    }
  }
  private func row(_ symbol: String, _ title: String, _ subtitle: String? = nil) -> some View {
    HStack(spacing: 14) {
      Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline).foregroundStyle(.primary)
        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
      }
    }
  }
}
