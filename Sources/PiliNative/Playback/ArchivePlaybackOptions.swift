import SwiftUI

/// What the video page lends the 更多 sheet: things that open the page's own panels.
struct ArchiveMoreActions {
  var video: Video? = nil
  var cid: Int64? = nil
  var story: InteractiveStory? = nil
  var listen: (() -> Void)? = nil
  var enqueue: (() -> Void)? = nil
  var danmakuList: (() -> Void)? = nil
  var danmakuSettings: (() -> Void)? = nil
  var sponsor: (() -> Void)? = nil
  var reload: (() -> Void)? = nil
}

/// The original's player 更多 sheet (header_control showSettingSheet): one list of icon rows —
/// 稍后再看, 笔记, 离线缓存, 保存封面, 定时关闭, 重载视频, 音量, 线路, a chip row, then 画质,
/// 音质, 内核, 播放顺序, 弹幕列表/设置, 字幕 — instead of a grouped settings form.
struct ArchivePlaybackOptions: View {
  @ObservedObject var model: PlayerModel
  var actions = ArchiveMoreActions()
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @ObservedObject private var sleep = PlaybackSleepTimer.shared
  @AppStorage("detail.summary") private var allowSummary = false
  @AppStorage("sponsor.enabled") private var sponsorEnabled = false
  @State private var notice: String?
  @State private var capturing = false
  @AppStorage(SpeedPresets.key) private var speedData = Data()
  @State private var speed = 1.0
  var body: some View {
    PiliNavigationStack {
      List {
        // The original sheet opens on its speed row; the phone's portrait player has no speed
        // button of its own.
        Section {
          speedRow.listRowInsets(EdgeInsets(top: 10, leading: 0, bottom: 10, trailing: 0))
        }
        Section {
          if let aid = actions.video?.aid ?? actions.video.flatMap({ ArchiveNumber.av($0.bvid) }) {
            row("clock", "添加至「稍后再看」") { watchLater(aid) }
          }
          if let video = actions.video, let aid = video.aid, let cid = actions.cid {
            NavigationLink {
              ArchiveNotes(aid: aid, interactive: video.rights?.is_stein_gate == 1, model: model, cid: cid, videoTitle: video.title)
            } label: { label("note.text", "查看笔记") }
          }
          if let video = actions.video, let cid = actions.cid, !model.isPreview {
            NavigationLink { DeferredPage { CacheSelection(video: video, cid: cid) } } label: {
              label("arrow.down.circle", "离线缓存")
            }
          }
          if let cover = actions.video?.cover {
            row("photo", "保存封面") {
              Task {
                do { _ = try await GalleryAssets().savePictures([.init(cover)]); notice = "封面已保存" }
                catch { notice = error.localizedDescription }
              }
            }
          }
          NavigationLink { DeferredPage { SleepTimerForm(live: false) } } label: {
            label("hourglass", "定时关闭", subtitle: sleepSubtitle)
          }
          if let reload = actions.reload { row("arrow.clockwise", "重载视频") { close(reload) } }
          NavigationLink { DeferredPage { AudioLevelSettings() } } label: { label("speaker.wave.2", "播放器音量") }
          HStack {
            label("icloud", "视频线路", subtitle: "无法播放请切换")
            Spacer(minLength: 8)
            PlayerLineButton(model: model)
          }
        }
        Section {
          chips.listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        }
        Section {
          Menu {
            ForEach(model.availableQualities, id: \.self) { quality in
              Button(StreamQuality.name(quality)) {
                Task { await model.changeQuality(quality, manualVideo: true) }
              }
            }
          } label: {
            label("play.circle", "选择画质",
              subtitle: "当前画质 " + (model.switching ? "切换中" : StreamQuality.name(model.quality)))
          }.disabled(model.availableQualities.isEmpty || model.switching)
          if !model.audioChoices.isEmpty {
            Menu {
              ForEach(model.audioChoices, id: \.self) { quality in
                Button(PlaybackOption.audioName(quality)) {
                  Task {
                    await model.changeQuality(
                      model.availableQualities.contains(model.quality)
                        ? model.quality : (model.availableQualities.first ?? 0), manualAudio: quality)
                  }
                }
              }
            } label: { label("opticaldisc", "选择音质") }.disabled(model.switching)
          }
          NavigationLink { DeferredPage { PlaybackEngineSettings() } } label: { label("cpu", "播放器内核") }
          Menu {
            RepeatPicker(session: model.preferences)
          } label: { label("repeat", "播放顺序") }
          SessionPlaybackSettings(session: model.preferences)
        }
        Section {
          if let open = actions.danmakuList { row("list.bullet", "弹幕列表") { close(open) } }
          if let open = actions.danmakuSettings { row("text.bubble.badge.gearshape", "弹幕设置") { close(open) } }
          SubtitlePicker(model: model)
          SpokenTrackPicker(model: model)
          if let video = actions.video, let cid = actions.cid {
            if let chapters = actions.story?.positions?.chapters, !chapters.isEmpty {
              NavigationLink {
                ArchiveChapterPanel(model: model, bvid: video.bvid, cid: cid, initial: chapters)
              } label: { label("list.bullet.rectangle", "分段", subtitle: "\(chapters.count) 段") }
            }
            if allowSummary {
              NavigationLink {
                VideoSummaryView(video: video, cid: cid, jump: { model.seek($0) })
              } label: { label("text.quote", "视频总结") }
            }
          }
          if sponsorEnabled, let open = actions.sponsor { row("forward.end", "空降标记") { close(open) } }
        }
        if let notice {
          Text(notice).font(.footnote).foregroundStyle(.secondary).listRowBackground(Color.clear)
        }
      }
      .listStyle(.insetGrouped).listSectionSpacing(12)
      .buttonStyle(.plain)
      .navigationTitle("更多").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
    .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
  }
  private var speedRow: some View {
    VStack(alignment: .leading, spacing: 10) {
      label("gauge.with.dots.needle.67percent", "播放速度").padding(.horizontal, 20)
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 8) {
          ForEach(SpeedPresets.decode(speedData), id: \.self) { s in
            let on = abs(speed - s) < 0.001
            Button {
              speed = s
              model.rate = Float(s)
              TouchFeedback.light()
            } label: {
              Text(s.formatted() + "×").font(.footnote.weight(on ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(on ? Color.accentColor : Color.primary)
                .padding(.horizontal, 14).frame(height: 32)
                .background(on ? Color.accentColor.opacity(0.14) : Color(uiColor: .secondarySystemBackground), in: Capsule())
                .contentShape(Capsule())
            }
            .accessibilityLabel(s.formatted() + "倍速").accessibilityAddTraits(on ? .isSelected : [])
          }
        }
        .padding(.horizontal, 16)
      }
    }
    .onAppear { speed = Double(model.rate) }
  }
  /// 听视频 / 加入待播 / 小窗 / 截图 / AirPlay, as the original's chip row under the first group.
  private var chips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 10) {
        if let listen = actions.listen {
          Button { close(listen) } label: { ArchiveToolChip(title: "听视频", symbol: "headphones") }
        }
        Button {
          let engine = model.engine
          close { NotificationCenter.default.post(name: .piliStartPictureInPicture, object: engine) }
        } label: { ArchiveToolChip(title: "小窗", symbol: "pip.enter") }
          .disabled(!model.ready)
        if let enqueue = actions.enqueue {
          Button { enqueue(); notice = "已加入待播" } label: {
            ArchiveToolChip(title: "加入待播", symbol: "text.line.first.and.arrowtriangle.forward")
          }
        }
        Button { capturing = true } label: { ArchiveToolChip(title: "截图", symbol: "camera") }
          .disabled(!model.ready)
          .sheet(isPresented: $capturing) { CapturePanel(model.engine).presentationDetents([.medium, .large]) }
        OutputRouteButton().frame(width: 34, height: 34).disabled(!model.engine.supportsSystemVideo)
          .background(Color(uiColor: .secondarySystemBackground), in: Circle())
      }
      .buttonStyle(.plain).foregroundStyle(.primary).padding(.horizontal, 16)
    }
  }
  private var sleepSubtitle: String? {
    switch sleep.state {
    case .off: return nil
    case .scheduled(let end, _):
      let left = max(0, Int(end.timeIntervalSinceNow))
      return "剩余 " + String(format: "%02d:%02d", left / 60, left % 60)
    case .finishingItem: return "本集结束时停止"
    }
  }
  private func label(_ symbol: String, _ title: String, subtitle: String? = nil) -> some View {
    HStack(spacing: 14) {
      Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline).foregroundStyle(.primary)
        if let subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary) }
      }
      Spacer(minLength: 0)
    }
    .contentShape(Rectangle())
  }
  private func row(_ symbol: String, _ title: String, subtitle: String? = nil, _ action: @escaping () -> Void) -> some View {
    Button(action: action) { label(symbol, title, subtitle: subtitle) }
  }
  /// Closes the sheet first, then opens the page's own panel (two sheets cannot overlap).
  private func close(_ then: @escaping () -> Void) {
    dismiss()
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { then() }
  }
  private func watchLater(_ aid: Int64) {
    guard let uid = accounts.state.active else { notice = "请先登录"; return }
    Task {
      do {
        try await BiliAPI.shared.submit("/x/v2/history/toview/add", ["aid": String(aid)], expectedAccount: uid)
        notice = "已添加至稍后再看"
      } catch { notice = error.localizedDescription }
    }
  }
}
