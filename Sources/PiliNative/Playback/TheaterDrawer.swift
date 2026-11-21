import SwiftUI

/// The fullscreen player and its 更多 panel. As in the reference player (and the original's video
/// sheet), the panel lies over the picture — at the right in landscape, along the bottom of a
/// portrait screen — and a tap anywhere else puts it away. The picture is never resized, so the
/// player view is never rebuilt.
///
/// The panel animates itself: `open` arrives through the fullscreen host, which does not carry the
/// caller's transaction, so a `withAnimation` around the change never reached it.
struct TheaterWorkspace<Picture: View, Panel: View>: View {
  let open: Bool
  let close: () -> Void
  @ViewBuilder let picture: () -> Picture
  @ViewBuilder let panel: () -> Panel
  var body: some View {
    GeometryReader { frame in
      let size = frame.size
      let wide = size.width > size.height
      let safe = WindowMetrics.safeInsets
      // Clear of the island only on its own side; the other edge has nothing to avoid.
      let edge = wide && !WindowMetrics.housingAtTrailing ? 0 : safe.trailing
      ZStack {
        picture().frame(width: size.width, height: size.height)
        if open {
          // The picture dims a little beside the panel; a tap on it closes the panel.
          Color.black.opacity(0.28)
            .contentShape(Rectangle())
            .onTapGesture { close() }
            .accessibilityHidden(true)
            .ignoresSafeArea()
            .transition(.opacity)
          // To the screen's edges (this view keeps to the safe area); the panel's contents keep
          // clear of the island and the home indicator by `theaterPanelInsets` instead.
          panel()
            .environment(\.theaterPanelInsets, wide
              ? EdgeInsets(top: safe.top, leading: 0, bottom: safe.bottom, trailing: edge)
              : EdgeInsets(top: 0, leading: safe.leading, bottom: safe.bottom, trailing: safe.trailing))
            .frame(width: wide ? TheaterPanelMetrics.width + edge : nil)
            .frame(maxWidth: wide ? nil : .infinity, maxHeight: wide ? .infinity : nil)
            .frame(height: wide ? nil : (size.height + safe.top + safe.bottom) * 0.62)
            .background { TheaterPanelBackground() }
            .clipShape(UnevenRoundedRectangle(
              topLeadingRadius: wide ? 0 : 18, topTrailingRadius: wide ? 0 : 18, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: wide ? .trailing : .bottom)
            .ignoresSafeArea()
            .transition(.move(edge: wide ? .trailing : .bottom))
            .accessibilityAction(.escape) { close() }
        }
      }
      .frame(width: size.width, height: size.height)
      .animation(PlayerChromeMotion.panel, value: open)
    }
  }
}

enum TheaterPanelMetrics {
  /// About the reference player's panel (320 dp), plus the safe area on that side.
  static let width: CGFloat = 340
}

private struct TheaterPanelInsetsKey: EnvironmentKey { static let defaultValue = EdgeInsets() }
private extension EnvironmentValues {
  var theaterPanelInsets: EdgeInsets {
    get { self[TheaterPanelInsetsKey.self] }
    set { self[TheaterPanelInsetsKey.self] = newValue }
  }
}

/// The picture frosted and darkened under the panel, as under the fullscreen bars' panels (the
/// reference player uses 88 % black). Every page of the panel shows through to it.
private struct TheaterPanelBackground: View {
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var body: some View {
    ZStack {
      if reduceTransparency {
        Color.black
      } else {
        Rectangle().fill(.ultraThinMaterial)
        Color.black.opacity(0.72)
      }
    }
    .environment(\.colorScheme, .dark)
  }
}

struct TheaterSubject {
  let cid: Int64, oid: Int64?, type: Int
  var bvid: String? = nil, aid: Int64? = nil, creator: Int64? = nil
  var introduction: String? = nil, interactive = false, comments = true,shortcutCanFollow=true
}

/// The panel's pages, built when they are opened.
private enum TheaterPanelRoute: Hashable, Identifiable {
  case sleep, subtitles, bullets, bulletList, comments, notes, chapters, playlist, sponsor
  case decoder, engine, volume, info, address
  var id: Self { self }
}

/// 更多 in fullscreen, after the reference player's panel: a grid of switches and pages, then
/// speed, play order and picture size as words with the current one lit, then the remaining
/// pages. Every page it opens is drawn with the same parts (TheaterPanelKit) on the same ground,
/// under the same inline title bar.
struct TheaterTools: View {
  @ObservedObject var model: PlayerModel
  let subject: TheaterSubject?, playlist: AnyView?, close: () -> Void
  var bulletSnapshot:(()->[Bullet])?=nil
  @Environment(\.theaterPanelInsets) private var insets
  @State private var route: TheaterPanelRoute?
  var body: some View {
    PiliNavigationStack {
      TheaterPanelRoot(
        model: model, preferences: model.preferences, picture: PictureSession.shared(model.engine),
        captions: model.captions, subject: subject, playlist: playlist != nil,
        route: $route, close: close)
        .navigationDestination(item: $route) { page($0) }
    }
    .scrollContentBackground(.hidden)
    .padding(insets)
    .environment(\.colorScheme, .dark)
  }
  @ViewBuilder private func page(_ route: TheaterPanelRoute) -> some View {
    switch route {
    case .sleep: TheaterPanelSleep()
    case .subtitles: TheaterPanelSubtitles(session: model.captions, refresh: model.reloadSubtitleCatalog)
    case .bullets: TheaterPanelBullets()
    case .decoder: TheaterPanelDecoder()
    case .engine: TheaterPanelEngine()
    case .volume: TheaterPanelVolume()
    case .info: TheaterPanelInfo(player: model.engine, model: model)
    case .bulletList:
      if let s = subject {
        DanmakuList(cid: s.cid, aid: s.aid, duration: model.duration, current: model.seconds, seek: model.seek, snapshot: bulletSnapshot)
          .id(s.cid).modifier(TheaterPanelPage(title: "弹幕列表"))
      }
    case .comments:
      if let s = subject, let id = s.oid {
        Discussion(oid: id, type: s.type, owner: s.creator, intro: s.introduction)
          .environment(\.replyPlayback, ReplyPlaybackTarget(duration: model.duration, seek: model.seek, model: model))
          .id("\(s.type):\(id)").modifier(TheaterPanelPage(title: "评论"))
      }
    case .notes:
      if let s = subject, let aid = s.aid {
        ArchiveNotes(aid: aid, interactive: s.interactive, model: model, cid: s.cid, videoTitle: nil)
          .modifier(TheaterPanelPage(title: "笔记"))
      }
    case .chapters:
      if let s = subject, let bv = s.bvid {
        ArchiveChapterPanel(model: model, bvid: bv, cid: s.cid).modifier(TheaterPanelPage(title: "分段"))
      }
    case .playlist:
      if let playlist { playlist.modifier(ReplyEdgeDismiss()).modifier(TheaterPanelPage(title: "选集")) }
    case .sponsor: SponsorList(model: model, inlineEditor: true).modifier(TheaterPanelPage(title: "空降标记"))
    case .address:
      if let grant = model.addressGrant {
        ArchiveSourceEditor(model: model, grant: grant).modifier(TheaterPanelPage(title: "播放地址"))
      }
    }
  }
}

private struct TheaterPanelRoot: View {
  @ObservedObject var model: PlayerModel
  @ObservedObject var preferences: PlayerSessionPreferences
  @ObservedObject var picture: PictureSession
  @ObservedObject var captions: SubtitleSession
  let subject: TheaterSubject?
  let playlist: Bool
  @Binding var route: TheaterPanelRoute?
  let close: () -> Void
  @ObservedObject private var sleep = PlaybackSleepTimer.shared
  @AppStorage("detail.chapters") private var chapters = true
  @AppStorage("sponsor.enabled") private var sponsor = false
  @AppStorage("player.trend") private var trend = false
  @AppStorage(SpeedPresets.key) private var speeds = Data()
  @AppStorage("play.gravity") private var gravity = PictureFit.fit.rawValue
  @AppStorage(DecoderPreference.enabledKey) private var hardware = true
  @AppStorage(PlaybackEngineKind.key) private var engine = PlaybackEngineKind.mpv.rawValue
  @AppStorage("audio.gainPercent") private var gain = 100.0
  @State private var rate = 1.0
  var body: some View {
    TheaterPanelScroll(title: "更多", header: false) {
      features
      TheaterPanelDivider()
      TheaterPanelSection("播放速度") {
        let presets = SpeedPresets.decode(speeds)
        TheaterPanelChoices(options: presets.map { ($0, $0.formatted(.number.precision(.fractionLength(1...2)))) },
          selected: presets.first { abs($0 - rate) < 0.001 }) { s in
            rate = s
            model.rate = Float(s)
          }
      }
      TheaterPanelDivider()
      TheaterPanelSection("播放方式") {
        TheaterPanelChoices(options: VideoRepeat.allCases.map { ($0, $0.label) }, selected: preferences.repeatMode) {
          preferences.repeatMode = $0
        }
      }
      TheaterPanelDivider()
      TheaterPanelSection("画面尺寸") {
        TheaterPanelChoices(options: PictureFit.allCases.map { ($0.rawValue, $0.title) }, selected: gravity) { value in
          picture.changedItem = model.engine.playbackItem.map(ObjectIdentifier.init)
          gravity = value
        }
      }
      if !model.audioChoices.isEmpty {
        TheaterPanelDivider()
        TheaterPanelSection("音质") {
          TheaterPanelChoices(options: model.audioChoices.map { ($0, PlaybackOption.audioName($0)) },
            selected: model.streamInfo?.audioID, disabled: model.switching) { id in
              let video = model.availableQualities.contains(model.quality) ? model.quality : model.availableQualities.first ?? 0
              Task { await model.changeQuality(video, manualAudio: id) }
            }
        }
      }
      if !model.spokenTracks.isEmpty {
        TheaterPanelDivider()
        TheaterPanelSection("配音语言") {
          TheaterPanelChoices(options: [("", "默认原声")] + model.spokenTracks.map { ($0.id, $0.label) },
            selected: model.spokenLanguage ?? "", disabled: model.switching) { id in
              let track = model.spokenTracks.first { $0.id == id }
              Task { await model.changeLanguage(track) }
            }
        }
      }
      TheaterPanelDivider()
      rows.padding(.top, 4)
    }
    .onAppear { rate = Double(model.rate) }
    .onReceive(model.engine.statePublisher) { _ in rate = Double(model.rate) }
  }

  private func open(_ to: TheaterPanelRoute) {
    TouchFeedback.light()
    route = to
  }

  // MARK: Grid

  /// Five to a row, as the reference player's.
  private var features: some View {
    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 5), spacing: 0) {
      TheaterPanelFeature(symbol: "play.square.stack", title: "后台播放", on: preferences.background) {
        TouchFeedback.light()
        preferences.background.toggle()
      }
      TheaterPanelFeature(symbol: "arrow.left.and.right.righttriangle.left.righttriangle.right",
        title: "镜像", on: picture.mirrorX) {
          TouchFeedback.light()
          picture.mirrorX.toggle()
        }
      TheaterPanelFeature(symbol: "pip.enter", title: "小窗") {
        TouchFeedback.light()
        let engine = model.engine
        close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
          NotificationCenter.default.post(name: .piliStartPictureInPicture, object: engine)
        }
      }
      .disabled(!model.ready)
      TheaterPanelFeature(symbol: "hourglass", title: sleepTitle, on: sleepTitle != "定时关闭") { open(.sleep) }
      TheaterPanelFeature(symbol: captions.first == nil ? "captions.bubble" : "captions.bubble.fill",
        title: "字幕", on: captions.first != nil) { open(.subtitles) }
      TheaterPanelFeature(symbol: "slider.horizontal.3", title: "弹幕设置") { open(.bullets) }
      if let s = subject, s.cid > 0 {
        TheaterPanelFeature(symbol: "list.bullet", title: "弹幕列表") { open(.bulletList) }
      }
      if let s = subject, let id = s.oid, id > 0, s.comments {
        TheaterPanelFeature(symbol: "text.bubble", title: "评论") { open(.comments) }
      }
      if let s = subject, s.aid != nil, s.type == 1, s.bvid != nil {
        TheaterPanelFeature(symbol: "note.text", title: "笔记") { open(.notes) }
      }
      if chapters, subject?.bvid != nil {
        TheaterPanelFeature(symbol: "list.bullet.rectangle", title: "分段") { open(.chapters) }
      }
      if playlist {
        TheaterPanelFeature(symbol: "list.number", title: "选集") { open(.playlist) }
      }
      if sponsor, subject?.bvid != nil {
        TheaterPanelFeature(symbol: "forward.end", title: "空降") { open(.sponsor) }
      }
    }
    .padding(.horizontal, 6).padding(.vertical, 6)
  }
  private var sleepTitle: String {
    switch sleep.state {
    case .off: return "定时关闭"
    case .scheduled(let end, _):
      let left = max(0, Int(end.timeIntervalSinceNow))
      return String(format: "%02d:%02d", left / 60, left % 60)
    case .finishingItem: return "本集结束"
    }
  }

  // MARK: Rows

  private var rows: some View {
    VStack(spacing: 0) {
      TheaterPanelAction(symbol: "av.remote", title: "解码格式", value: hardware ? "硬件优先" : "软件", chevron: true) { open(.decoder) }
      TheaterPanelAction(symbol: "cpu", title: "播放器内核",
        value: PlaybackEngineKind(rawValue: engine)?.title, chevron: true) { open(.engine) }
      TheaterPanelAction(symbol: "speaker.wave.2", title: "播放器音量", value: "\(Int(gain))%", chevron: true) { open(.volume) }
      TheaterPanelAction(symbol: "info.circle", title: "播放信息", chevron: true) { open(.info) }
      if model.addressGrant != nil {
        TheaterPanelAction(symbol: "link", title: "播放地址", chevron: true) { open(.address) }
      }
      TheaterPanelAction(symbol: "arrow.clockwise", title: "重载视频", value: model.switching ? "载入中" : nil) {
        TouchFeedback.light()
        Task { await model.reloadPlayback() }
      }
      .disabled(model.switching || model.timeline.source == nil)
      AudioOnlySwitch(player: model.engine) { on in
        TheaterPanelSwitch(symbol: "headphones", title: "仅播放音频", on: on)
      }
      if trend { TheaterTrendSwitch(timeline: model.timeline) }
    }
  }
}

/// A cell of the grid: a symbol over its name, lit while it is on.
private struct TheaterPanelFeature: View {
  let symbol: String, title: String
  var on = false
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      VStack(spacing: 6) {
        Image(systemName: symbol).font(.system(size: 20))
          .frame(width: 28, height: 26)
          .contentTransition(.symbolEffect(.replace))
        Text(title).font(.system(size: 11.5)).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
      }
      .foregroundStyle(on ? Color.accentColor : .white)
      .frame(maxWidth: .infinity).frame(height: 64)
      .contentShape(Rectangle())
      .animation(.easeOut(duration: 0.15), value: on)
    }
    .buttonStyle(PlayerPressStyle())
    .accessibilityLabel(title)
    .accessibilityAddTraits(on ? .isSelected : [])
  }
}

private struct TheaterTrendSwitch: View {
  @ObservedObject var timeline: TimelineState
  var body: some View {
    TheaterPanelSwitch(symbol: "waveform.path.ecg", title: "显示高能进度", on: $timeline.showTrendOverlay)
  }
}
