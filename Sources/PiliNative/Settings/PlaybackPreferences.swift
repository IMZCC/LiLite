import SwiftUI

struct PlayerPreferenceValues: Codable {
  static let flags = [
    "play.guestPublicHD", "network.negotiateHTTP2", "network.allowInvalidCertificates", "decoder.hardware", "play.temporaryPreferences", "player.longControls", "player.shrink",
    "player.edgeToEdge", "play.systemMedia", "layout.horizontal", "layout.member",
    "layout.playlist",
    "layout.verticalMedia", "social.waterfall",
    "vod.independentAudio", "vod.speedTest", "appearance.decorate", "emote.preview",
    "reply.wordSearch", "web.external", "reply.openFirst", "discovery.pgcTimeline",
    "creator.shop", "images.live", "images.sidePreview",
    "images.silentSave", "images.longMenu",
    "live.paidFullscreen", "live.medal", "dm.tap", "feed.hotEntrances", "feed.mobile",
    "feed.keepPrevious",
    "feed.retainedTip", "feed.featuredFirst",
    "search.defaultWord", "detail.online",
    "dm.quietPiP", "play.preinitialize", "play.pauseWhenBackground", "updates.automatic", "player.scrollVolume", "player.keyboard", "appearance.pureBlack", "detail.dark", "theater.battery",
    "theater.actionBar",
    "play.reverseFirst", "detail.argue",
    "detail.expandIntro", "detail.expandWide",
    "badge.periodic",
    "social.verifyReply", "social.verifyPost", "social.dispute",
    "social.interaction",
    "social.actionBar", "social.allFollowed",
    "social.expandLive",
    "play.onEntry", "play.background", "play.continuePart", "library.playAll", "detail.quickFav",
    "ui.haptics", "reply.save",
    "reply.edgeDismiss", "reply.composerAutoHide",
    "detail.episodeReplies",
    "search.hot", "search.picks", "search.suggest", "live.showChat",
    "player.quickDouble", "player.slideLevels", "player.doubleSpeed", "player.relativeSeek", "player.seekCurve",
    "detail.summary", "detail.chapters", "detail.related", "detail.replies", "detail.coinLike",
    "theater.autoEnter", "theater.autoExit", "theater.swipe", "theater.reverseSwipe",
    "theater.lockButton", "theater.captureButton", "play.autoPiP", "caption.drag",
    "player.seekPreview", "player.trend",
  ]
  static let limits: [String: ClosedRange<Double>] = [
    "player.upscale": 0...2,
    "player.bottomProgress": 0...3,
    "play.bufferMB": 0...512, "live.bufferMB": 0...512,
    "reading.bodyPercent": 10...90, "social.upPanelPosition": 0...4,
    "creator.initialSection": 0...7,
    "images.nightTint": 0...4_294_967_295, "ui.toastOpacity": 0...1,
    "grid.recommendWidth": 150...500, "grid.cardWidth": 150...500,
    "badge.dynamicMode": 0...2, "badge.messageMode": 0...2, "badge.minutes": 1...1440,
    "badge.messageMask": 0...31,
    "social.defaultFeed": 0...3,
    "play.bufferSeconds": 0...3600, "live.bufferSeconds": 0...3600,
    "play.repeat": 0...4, "theater.orientation": 0...4,
    "reply.mainSort": 0...1, "reply.detailSort": 0...1,
    "images.quality": 1...100, "images.previewQuality": 1...100, "live.paidMode": 0...2,
    "live.paidOpacity": 0.1...1, "live.paidScale": 0.1...1,
    "live.paidWidth": 25...Double.greatestFiniteMagnitude,
    "layout.pageMotion": 0...16, "gesture.horizontalThreshold": 0...200, "list.refreshDisplacement": 10...100, "layout.interfaceScale": 0.5...2,
    "audio.gainPercent": 100...300, "player.seekStep": 1...180, "player.slideRange": 1...600,
    "player.holdSpeed": Double(Float.leastNonzeroMagnitude)...Double(Float.greatestFiniteMagnitude),
    "images.cacheBytes": 0...1_048_574_951_424,
    "follow.sort": 0...1, "network.retryCount": 0...8, "network.retryDelay": 0...1000,
    "caption.preference": 0...3, "caption.fullSize": 8...60, "caption.horizontal": 0...120,
    "caption.bottom": 0...200,
    "caption.opacity": 0...1, "caption.weight": 1...9, "caption.stroke": 0...5,
  ]
  var flags: [String: Bool], numbers: [String: Double]
  var quickFolder: String? = nil
  static func current(_ d: UserDefaults) -> Self {
    .init(
      flags: Dictionary(
        uniqueKeysWithValues: Self.flags.compactMap { k in
          (d.object(forKey: k) as? Bool).map { (k, $0) }
        }),
      numbers: Dictionary(
        uniqueKeysWithValues: limits.keys.compactMap { k in
          (d.object(forKey: k) as? NSNumber).map { (k, $0.doubleValue) }
        }), quickFolder: d.string(forKey: "detail.quickFolder").flatMap { $0.isEmpty ? nil : $0 })
  }
  func validate() throws {
    guard
      [
        "images.quality", "images.previewQuality", "reply.mainSort", "reply.detailSort",
        "images.nightTint", "badge.dynamicMode", "badge.messageMode", "badge.messageMask",
        "player.upscale", "player.bottomProgress", "badge.minutes", "social.upPanelPosition",
        "creator.initialSection",
        "social.defaultFeed", "play.repeat", "theater.orientation", "follow.sort",
        "network.retryCount",
        "network.retryDelay", "caption.preference",
      ].allSatisfy({
        k in
        numbers[k].map { Int(exactly: $0) != nil } ?? true
      }), numbers["live.paidMode"].map({ Int(exactly: $0) != nil }) ?? true,
      quickFolder.map({ text in Int64(text).map { $0 > 0 && String($0) == text } == true }) ?? true,
      flags.keys.allSatisfy(Self.flags.contains),
      numbers.allSatisfy({ Self.limits[$0.key]?.contains($0.value) == true })
    else { throw ServiceError("播放偏好超出可用范围") }
  }
  func apply(_ d: UserDefaults) {
    d.set(quickFolder, forKey: "detail.quickFolder")
    for k in Self.flags {
      if let v = flags[k] { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
    }
    for k in Self.limits.keys {
      if let v = numbers[k] { d.set(v, forKey: k) } else { d.removeObject(forKey: k) }
    }
  }
}
struct PlayerPreferencePanel: View {
  @AppStorage(PlayerSessionPreferences.temporaryKey) private var temporary = false
  @AppStorage(SystemMediaControls.key) private var systemMedia = true
  /// Unset follows the current window (the original's `isTablet`), so an unfolded iPhone Duo
  /// or a full-screen iPad gets the side layout and a folded Duo or a narrow window does not.
  @AppStorage("layout.horizontal") private var horizontalPref: Bool?
  private var horizontal: Bool { horizontalPref ?? WindowCanvas.shared.large }
  @AppStorage("layout.playlist") private var sideList: Bool?
  @AppStorage("layout.member") private var sideMember: Bool?
  @AppStorage("layout.verticalMedia") private var tall = false
  @AppStorage("player.quickDouble") private var quick = false
  @AppStorage(PlayerSlide.seekCurveKey) private var seekCurve = true
  @AppStorage("player.slideLevels") private var slide = true
  @AppStorage("player.doubleSpeed") private var double = false
  @AppStorage("player.relativeSeek") private var relative = false
  @AppStorage("player.seekStep") private var step = 10.0
  @AppStorage("player.slideRange") private var travel = 90.0
  @AppStorage("player.holdSpeed") private var hold = 3.0
  @AppStorage("detail.summary") private var summary = false
  @AppStorage("detail.online") private var online = false
  @AppStorage("detail.chapters") private var chapters = true
  @AppStorage("detail.related") private var related = true
  @AppStorage("detail.replies") private var replies = true
  @AppStorage("detail.coinLike") private var coinLike = false
  @AppStorage("detail.quickFav") private var quickFav = false
  @AppStorage("play.continuePart") private var continuePart = true
  @AppStorage("detail.argue") private var argue = true
  @AppStorage("detail.dark") private var darkVideo = false
  @AppStorage(SubtitlePreference.key) private var captionPreference = 0
  @AppStorage("dm.quietPiP") private var quietPiP = false
  @AppStorage("player.scrollVolume") private var scrollVolume = true
  @AppStorage("player.keyboard") private var keyboard = true
  @AppStorage("theater.battery") private var battery = true
  @AppStorage("theater.actionBar") private var fsActions = true
  @AppStorage("play.reverseFirst") private var reverseFirst = true
  @AppStorage("detail.expandIntro") private var expandIntro = false
  @AppStorage("detail.expandWide") private var expandWide = false
  @AppStorage(VideoTransport.autoKey) private var onEntry = true
  @AppStorage(VideoTransport.backgroundKey) private var backgroundPlay = false
  @AppStorage(VideoTransport.bufferKey) private var networkBuffer = 16.0
  @AppStorage(VideoTransport.liveBufferKey) private var liveBuffer = 0.0
  @AppStorage("ui.haptics") private var haptics = false
  @AppStorage("play.autoPiP") private var pip = false
  @AppStorage("theater.orientation") private var orientationPref: Int?
  private var orientation: Int { orientationPref ?? TheaterOrientation.defaultMode }
  @AppStorage("theater.autoEnter") private var autoEnter = false
  @AppStorage("theater.autoExit") private var autoExit = true
  @AppStorage("theater.swipe") private var screenSwipe = true
  @AppStorage("theater.reverseSwipe") private var reverseSwipe = false
  @AppStorage("theater.lockButton") private var lockButton = true
  @AppStorage("theater.captureButton") private var captureButton = true
  @AppStorage("player.seekPreview") private var seekPreview = true
  @AppStorage("player.trend") private var trend = false
  private func seconds(_ v: Double) -> String { v == 0 ? "自动" : v.formatted() + " 秒" }
  var body: some View {
    Form {
      Section {
        RepeatPicker()
        Toggle("进入详情页自动播放", isOn: $onEntry).settingAnchor("PlayerPreferencePanel/进入详情页自动播放")
        Toggle("进入后台时继续播放", isOn: $backgroundPlay).settingAnchor("PlayerPreferencePanel/进入后台时继续播放")
        Toggle("锁屏与控制中心播放控件", isOn: $systemMedia).settingAnchor("PlayerPreferencePanel/锁屏与控制中心播放控件")
        Toggle("提示上次观看的分 P", isOn: $continuePart).settingAnchor("PlayerPreferencePanel/续播上次观看的分 P")
        Toggle("分 P 或合集倒序后从首集播放", isOn: $reverseFirst).settingAnchor("PlayerPreferencePanel/分 P 或合集倒序后从首集播放")
        Toggle("播放器调整仅用于本次播放", isOn: $temporary).settingAnchor("PlayerPreferencePanel/播放器调整仅用于本次播放")
        Toggle("触感反馈", isOn: Binding(get: { haptics }, set: { enabled in
          haptics = enabled
          if enabled { TouchFeedback.light() }
        })).settingAnchor("PlayerPreferencePanel/触感反馈")
      } header: {
        Text("播放")
      } footer: {
        Text("“仅用于本次播放”开启后，在播放器里改的画质、倍速等不会保存为默认值。")
      }.settingAnchor("PlayerPreferencePanel/视频详情")
      Section("详情页内容") {
        Toggle("默认展开视频简介", isOn: $expandIntro).settingAnchor("PlayerPreferencePanel/默认展开视频简介")
        if !expandIntro { Toggle("横屏时展开简介", isOn: $expandWide).settingAnchor("PlayerPreferencePanel/横屏时展开简介") }
        Toggle("显示视频总结", isOn: $summary).settingAnchor("PlayerPreferencePanel/显示视频总结")
        Toggle("显示视频章节", isOn: $chapters).settingAnchor("PlayerPreferencePanel/显示视频章节")
        Toggle("显示相关推荐", isOn: $related).settingAnchor("PlayerPreferencePanel/显示相关推荐")
        Toggle("显示评论入口", isOn: $replies).settingAnchor("PlayerPreferencePanel/显示评论入口")
        Toggle("显示正在观看人数", isOn: $online).settingAnchor("PlayerPreferencePanel/显示正在观看人数")
        Toggle("显示视频争议提示", isOn: $argue).settingAnchor("PlayerPreferencePanel/显示视频争议提示")
        Toggle("视频详情使用深色外观", isOn: $darkVideo).settingAnchor("PlayerPreferencePanel/视频详情使用深色外观")
      }
      Section("互动") {
        Toggle("投币时同时点赞", isOn: $coinLike).settingAnchor("PlayerPreferencePanel/投币时同时点赞")
        Toggle("快速收藏", isOn: $quickFav).settingAnchor("PlayerPreferencePanel/快速收藏")
        if quickFav { NavigationLink("快速收藏夹") { DeferredPage { QuickFolderChoice() } }.settingAnchor("PlayerPreferencePanel/快速收藏夹") }
      }
      Section {
        NavigationLink("播放控件与画面缩放") { DeferredPage { ViewportSettings() } }.settingAnchor("PlayerPreferencePanel/播放控件与画面缩放")
        Toggle("使用横屏布局", isOn: $horizontalPref.or { WindowCanvas.shared.large }).settingAnchor("PlayerPreferencePanel/使用横屏布局")
        Toggle("横屏时在标签栏选集", isOn: Binding(get: { sideList ?? horizontal }, set: { sideList = $0 })).settingAnchor("PlayerPreferencePanel/横屏时在标签栏选集")
        Toggle(
          "横屏时在侧栏打开 UP 主空间",
          isOn: Binding(get: { sideMember ?? horizontal }, set: { sideMember = $0 })).settingAnchor("PlayerPreferencePanel/横屏时在侧栏打开 UP 主空间")
        Toggle("扩大竖屏视频画面", isOn: $tall).settingAnchor("PlayerPreferencePanel/扩大竖屏视频画面")
      } header: {
        Text("画面布局")
      }.settingAnchor("PlayerPreferencePanel/画面布局")
      Section {
        NavigationLink("缓冲容量") { DeferredPage { MediaBufferSettings() } }.settingAnchor("PlayerPreferencePanel/缓冲容量")
        SettingStepper(title: "视频预缓冲", value: $networkBuffer, range: 0...3600, format: seconds)
        SettingStepper(title: "直播预缓冲", value: $liveBuffer, range: 0...3600, format: seconds)
      } header: {
        Text("网络缓冲")
      } footer: {
        Text("设为 0 时由系统根据网络状况自动决定。")
      }.settingAnchor("PlayerPreferencePanel/网络缓冲")
      Section("音画同步") { TimingSettings() }
      Section("播放时机") { PlaybackEntryOptions() }.settingAnchor("PlayerPreferencePanel/播放时机")
      Section {
        Toggle("拖动时预览画面", isOn: $seekPreview).settingAnchor("PlayerPreferencePanel/拖动时预览画面")
        Toggle("显示高能进度条", isOn: $trend).settingAnchor("PlayerPreferencePanel/显示高能进度条")
        Toggle("双击左右两侧快退或快进", isOn: $quick).settingAnchor("PlayerPreferencePanel/双击左右两侧快退或快进")
        if quick {
          SettingStepper(title: "快进快退", value: $step, range: 1...180) { "\(Int($0)) 秒" }
            .settingAnchor("PlayerPreferencePanel/快进快退")
        }
        Toggle("上下滑动调节亮度和音量", isOn: $slide).settingAnchor("PlayerPreferencePanel/上下滑动调节亮度和音量")
        Toggle("横滑进度随视频时长调整", isOn: $seekCurve).settingAnchor("PlayerPreferencePanel/横滑进度随视频时长调整")
        if !seekCurve {
          Toggle("按视频时长比例滑动", isOn: $relative).settingAnchor("PlayerPreferencePanel/按视频时长比例滑动")
          SettingStepper(title: "横滑整屏", value: $travel, range: 1...600) { relative ? "\(Int($0))%" : "\(Int($0)) 秒" }
        }
        Toggle("长按时使用当前倍速的两倍", isOn: $double).settingAnchor("PlayerPreferencePanel/长按时使用当前倍速的两倍")
        if !double {
          NavigationLink { DeferredPage { SpeedSettings() } } label: {
            LabeledContent("长按倍速", value: hold.formatted() + "×")
          }.settingAnchor("PlayerPreferencePanel/长按倍速")
        }
      } header: {
        Text("手势")
      } footer: {
        Text("“横滑整屏”是手指横向划过整个画面时跳转的距离。")
      }.settingAnchor("PlayerPreferencePanel/播放手势")
      Section("全屏") {
        Picker("全屏方向", selection: $orientationPref.or { TheaterOrientation.defaultMode }) {
          ForEach(FullscreenMode.allCases, id: \.rawValue) { v in Text(v.title).tag(v.rawValue) }
        }.settingAnchor("PlayerPreferencePanel/全屏方向")
        Toggle("开始播放时进入全屏", isOn: $autoEnter).settingAnchor("PlayerPreferencePanel/开始播放时进入全屏")
        Toggle("播完退出全屏", isOn: $autoExit).settingAnchor("PlayerPreferencePanel/播完退出全屏")
        Toggle("上下滑动切换全屏", isOn: $screenSwipe).settingAnchor("PlayerPreferencePanel/上下滑动切换全屏")
        if screenSwipe { Toggle("反转全屏手势方向", isOn: $reverseSwipe).settingAnchor("PlayerPreferencePanel/反转全屏手势方向") }
        Toggle("全屏显示电量", isOn: $battery).settingAnchor("PlayerPreferencePanel/全屏显示电量")
        Toggle("全屏显示点赞、投币和收藏", isOn: $fsActions).settingAnchor("PlayerPreferencePanel/全屏显示点赞、投币和收藏")
        Toggle("全屏显示锁定按钮", isOn: $lockButton).settingAnchor("PlayerPreferencePanel/全屏显示锁定按钮")
        Toggle("全屏显示截图按钮", isOn: $captureButton).settingAnchor("PlayerPreferencePanel/全屏显示截图按钮")
      }
      Section("画中画") {
        Toggle("自动进入画中画", isOn: $pip).settingAnchor("PlayerPreferencePanel/自动进入画中画")
        Toggle("画中画时暂停加载视频弹幕", isOn: $quietPiP).settingAnchor("PlayerPreferencePanel/画中画时暂停加载视频弹幕")
      }
      Section("音频与字幕") {
        NavigationLink("播放器音量与均衡") { DeferredPage { AudioLevelSettings() } }.settingAnchor("PlayerPreferencePanel/播放器音量与均衡")
        Picker("默认字幕", selection: $captionPreference) {
          ForEach(SubtitlePreference.allCases, id: \.rawValue) { option in
            Text(option.title).tag(option.rawValue)
          }
        }.settingAnchor("PlayerPreferencePanel/默认字幕")
        NavigationLink("字幕样式") { DeferredPage { CaptionStylePanel() } }.settingAnchor("PlayerPreferencePanel/字幕样式")
      }
      Section {
        Toggle("滚轮调节音量", isOn: $scrollVolume).settingAnchor("PlayerPreferencePanel/滚轮调节音量")
        Toggle("启用播放快捷键", isOn: $keyboard).settingAnchor("PlayerPreferencePanel/启用播放快捷键")
      } header: {
        Text("键盘与鼠标")
      } footer: {
        if keyboard {
          Text("空格播放或暂停，方向键调节进度和音量，F 切换全屏，D 切换弹幕，M 静音，方括号切集，逗号和句点调倍速。")
        }
      }.settingAnchor("PlayerPreferencePanel/键盘与鼠标")
    }
    .animation(.snappy(duration: 0.25), value: [expandIntro, quickFav, quick, double, screenSwipe, keyboard])
    .navigationTitle("详情与播放控制")
  }
}
struct CaptionStylePanel: View {
  @AppStorage("play.subtitleSize") private var normal = 16.0
  @AppStorage("caption.fullSize") private var full = 24.0
  @AppStorage("caption.horizontal") private var h = 24.0
  @AppStorage("caption.bottom") private var b = 24.0
  @AppStorage("caption.opacity") private var opacity = 0.67
  @AppStorage("caption.weight") private var weight = 6.0
  @AppStorage("caption.stroke") private var stroke = 2.0
  @AppStorage("caption.drag") private var drag = false
  var body: some View {
    Form {
      Section {
        ZStack(alignment: .bottom) {
          LinearGradient(colors: [Color(white: 0.35), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
          CaptionLine(text: "字幕预览", interactive: true)
        }
        .frame(height: 170)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
      } footer: {
        if drag { Text("可以直接上下拖动预览中的字幕调整位置。") }
      }
      Section("字号") {
        MediaTextScaleControl(title: "字号", points: $normal, base: 16)
        MediaTextScaleControl(title: "全屏字号", points: $full, base: 16)
      }
      Section("样式") {
        SettingStepper(title: "字重", value: $weight, range: 1...9) { "\(Int($0))" }.settingAnchor("CaptionStylePanel/字重")
        SettingStepper(title: "描边", value: $stroke, range: 0...5, step: 0.5).settingAnchor("CaptionStylePanel/描边")
        SettingSlider(title: "背景不透明度", value: $opacity, range: 0...1).settingAnchor("CaptionStylePanel/背景不透明度")
      }
      Section("位置") {
        SettingStepper(title: "水平边距", value: $h, range: 0...100) { "\(Int($0))" }.settingAnchor("CaptionStylePanel/水平边距")
        SettingStepper(title: "底部边距", value: $b, range: 0...200) { "\(Int($0))" }.settingAnchor("CaptionStylePanel/底部边距")
        Toggle("允许拖动字幕", isOn: $drag).settingAnchor("CaptionStylePanel/允许拖动字幕")
      }
    }.navigationTitle("字幕样式")
  }
}
private enum CaptionInsetKey: EnvironmentKey { static let defaultValue: CGFloat = 0 }
extension EnvironmentValues {
  var captionMinimumBottom: CGFloat {
    get { self[CaptionInsetKey.self] }
    set { self[CaptionInsetKey.self] = newValue }
  }
}
struct CaptionLine: View {
  @Environment(\.captionMinimumBottom) private var controlsMinimum
  let text: String
  var fullscreen = false, interactive = false
  var controlInset: CGFloat = 0
  @AppStorage("play.subtitleSize") private var normal = 16.0
  @AppStorage("caption.fullSize") private var full = 24.0
  @AppStorage("caption.horizontal") private var h = 24.0
  @AppStorage("caption.bottom") private var b = 24.0
  @AppStorage("caption.opacity") private var opacity = 0.67
  @AppStorage("caption.weight") private var weight = 6.0
  @AppStorage("caption.stroke") private var stroke = 2.0
  @AppStorage("caption.drag") private var drag = false
  @State private var initial: Double?
  private var font: Font {
    let weights: [Font.Weight] = [
      .ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black,
    ]
    return .system(
      size: fullscreen ? full : normal, weight: weights[min(8, max(0, Int(weight) - 1))])
  }
  var body: some View {
    let glyph = Text(verbatim: text).font(font).multilineTextAlignment(.center)
    ZStack {
      if stroke > 0 && opacity == 0 {
        ForEach(0..<8, id: \.self) { i in
          glyph.foregroundStyle(.black).offset(
            x: cos(Double(i) * Double.pi / 4) * stroke / 2, y: sin(Double(i) * Double.pi / 4) * stroke / 2
          ).accessibilityHidden(true)
        }
      }
      glyph.foregroundStyle(.white)
    }.padding(4).background(.black.opacity(opacity), in: RoundedRectangle(cornerRadius: 3))
      .gesture(
        DragGesture().onChanged { v in
          guard interactive && drag else { return }
          if initial == nil { initial = b }
          b = max(0, min(200, ((initial ?? b) - v.translation.height).rounded()))
        }.onEnded { _ in initial = nil }, including: interactive && drag ? .all : .none
      )
      .allowsHitTesting(interactive && drag).padding(.horizontal, h).padding(
        .bottom, max(b + controlInset, controlsMinimum))
  }
}
