import SwiftUI
import UniformTypeIdentifiers

struct NativePrefs: Codable {
  var dynamicRegex: String?
  var hideGoods: Bool?
  var typeface: TypefaceChoice?
  var visualFPS: Int?
  var speeds: [Double]?
  var diagnosticLog: Bool?
  var hideLikeNotices: Bool?
  var version: Int = 1
  var appearance = "system"
  var accent = "rose"
  var themeSeed: Int?, paletteStyle: Int?, systemTint: Bool?
  var rate = 1.0
  var bullets = true
  var opacity = 1.0
  var area = 0.5
  var blocked = ""
  var remember: Bool? = true
  var quality: Int?, audioQuality: Int?, codec: String?, gravity: String?, subtitleSize: Double?,
    dmSize: Double?, fullDmSize: Double?
  var guestDevice: String?
  var scrollSpring: [Double]?
  var normalizer: String?, fallbackNormalizer: String?
  var videoSync: String?, autosync: String?
  var decoderChoices: String? = nil
  var apiProxy: APIProxy? = nil
  var vodLine: String? = nil
  var liveCDN: String? = nil
  var liveStream: [String]? = nil
  var sponsorEnabled: Bool?, sponsorAuto: Bool?, sponsorServer: String?, listenRepeat: String?
  var danmakuStyle: DanmakuStyle?
  var layout: NavigationLayout?
  var controls: PlayerPreferenceValues?
  var recommendation: RecommendationRules?
  var replyFilter: ReplyFilterRules?
  var networkMedia: NetworkMediaRules?
  var sponsorRules: SponsorRules?
  var episodeSkip: String?
  var historySync: Bool?
  var searchHistory = true
  static func current(_ d: UserDefaults = .standard) -> Self {
    var p = Self()
    p.appearance = d.string(forKey: "appearance") ?? p.appearance
    p.accent = d.string(forKey: "accent") ?? p.accent
    p.themeSeed = d.object(forKey: ThemeSeeds.seedKey) as? Int ?? ThemeSeeds.previous(d.string(forKey: "accent"))
    p.paletteStyle = d.object(forKey: ThemeSeeds.styleKey) as? Int ?? 10
    p.systemTint = d.bool(forKey: ThemeSeeds.systemKey)
    p.rate = d.object(forKey: "play.rate") as? Double ?? p.rate
    p.bullets = d.object(forKey: "video.danmaku.enabled") as? Bool ?? p.bullets
    p.opacity = d.object(forKey: "dm.opacity") as? Double ?? p.opacity
    p.area = d.object(forKey: "dm.area") as? Double ?? p.area
    p.blocked = d.string(forKey: "dm.blocked") ?? ""
    p.searchHistory = d.object(forKey: "search.save") as? Bool ?? true
    p.remember = d.object(forKey: "play.remember") as? Bool ?? true
    p.videoSync = d.string(forKey: PresentationMode.modeKey) ?? PresentationMode.system.rawValue
    p.autosync = d.string(forKey: PresentationMode.smoothingKey) ?? "0"
    p.quality = d.integer(forKey: "play.quality")
    p.audioQuality = d.integer(forKey: "play.audioQuality")
    p.dynamicRegex = d.string(forKey: "social.dynamicRegex")
    p.hideGoods = d.bool(forKey: "social.hideGoods")
    p.typeface = TypefaceChoice.current(d)
    p.visualFPS = d.integer(forKey: "display.fps")
    p.speeds = SpeedPresets.current(d)
    p.diagnosticLog = d.object(forKey: DiagnosticJournal.key) as? Bool ?? true
    p.hideLikeNotices = d.bool(forKey: "inbox.hideLikes")
    p.codec = d.string(forKey: "play.codec")
    p.gravity = d.string(forKey: "play.gravity")
    p.subtitleSize = d.object(forKey: "play.subtitleSize") as? Double ?? 16
    p.dmSize = d.object(forKey: "dm.fontSize") as? Double ?? 15
    p.fullDmSize = d.object(forKey: "dm.fullFontSize") as? Double ?? 18
    p.sponsorEnabled = d.bool(forKey: "sponsor.enabled")
    p.sponsorAuto = d.bool(forKey: "sponsor.auto")
    p.sponsorServer = d.string(forKey: "sponsor.server")
    p.guestDevice = MobileDeviceID.guest(d)
    p.scrollSpring = ScrollSpring.current(d).values
    p.normalizer = d.string(forKey: "audio.normalization") ?? "0"
    p.fallbackNormalizer = d.string(forKey: "audio.fallbackNormalization") ?? "0"
    p.decoderChoices = d.string(forKey: DecoderPreference.listKey) ?? "auto"
    p.apiProxy = APIProxy.current(d)
    p.vodLine = d.string(forKey: VODLine.key) ?? VODLine.backupUrl.rawValue
    p.liveCDN = d.string(forKey: "live.cdn")
    p.liveStream = d.stringArray(forKey: "live.stream")
    p.listenRepeat = d.string(forKey: "listen.repeat")
    p.historySync = d.object(forKey: "history.sync") as? Bool ?? true
    p.episodeSkip = d.string(forKey: "play.episodeSkip")
    p.danmakuStyle = DanmakuStyle.decode(d.data(forKey: DanmakuStyle.key) ?? Data())
    p.layout = NavigationLayout.current(d)
    p.controls = PlayerPreferenceValues.current(d)
    p.recommendation = RecommendationRules.current(d)
    p.replyFilter = ReplyFilterRules.current(d)
    p.sponsorRules = SponsorRules.current(d).padded()
    p.networkMedia = NetworkMediaRules.current(d)
    p.quality = p.networkMedia?.wifiVideo
    p.audioQuality = p.networkMedia?.wifiAudio
    return p
  }
  func validate() throws {
    guard version == 1, ["system", "light", "dark"].contains(appearance),
      ["rose", "blue", "orange", "purple"].contains(accent),
      themeSeed.map(ThemeSeeds.valid) ?? true, ThemeSeeds.styles.indices.contains(paletteStyle ?? 10),
      SpeedPresets.valid(rate), SpeedPresets.checked(speeds ?? SpeedPresets.defaults),
      (0...1).contains(opacity),
      (0.1...1).contains(area), blocked.utf8.count <= 16384
    else { throw ServiceError("备份包含不支持的设置") }
    guard PresentationMode(rawValue: videoSync ?? PresentationMode.system.rawValue) != nil,
      PresentationMode.validSmoothing(autosync ?? "0") != nil,
      PlaybackOption.qualities.contains(quality ?? 0),
      PlaybackOption.audio.contains(audioQuality ?? 0),
      PlaybackOption.codecs.contains(codec ?? "auto"),
      PlaybackOption.modes.contains(gravity ?? "fit"),
      (8...40).contains(subtitleSize ?? 16), (7.5...37.5).contains(dmSize ?? 15),
      (7.5...42).contains(fullDmSize ?? 18)
    else { throw ServiceError("备份包含不支持的播放设置") }
    if let base = sponsorServer {
      guard SelfHostedServiceURL.parse(base) != nil
      else { throw ServiceError("空降助手地址无效") }
    }
    if let guestDevice, !MobileDeviceID.valid(guestDevice) { throw ServiceError("设备标识无效") }
    if let scrollSpring, ScrollSpring(scrollSpring) == nil { throw ServiceError("回弹参数无效") }
    guard AudioFilterChoice.valid(normalizer ?? "0"), AudioFilterChoice.valid(fallbackNormalizer ?? "0") else {
      throw ServiceError("音量均衡参数无效")
    }
    if let decoderChoices, DecoderPreference.choices(decoderChoices) == nil {
      throw ServiceError("解码顺序无效")
    }
    _ = try apiProxy?.validated()
    if let vodLine, VODLine(rawValue: vodLine) == nil { throw ServiceError("视频线路无效") }
    if let liveCDN, LiveCDNOrigin(liveCDN) == nil { throw ServiceError("直播 CDN 地址无效") }
    if let liveStream, LiveFormat(liveStream) == nil { throw ServiceError("直播格式无效") }
    if let listenRepeat, AudioSequence(rawValue: listenRepeat) == nil {
      throw ServiceError("播放顺序无效")
    }
    guard EpisodeSkipMode(rawValue: episodeSkip ?? "once") != nil else {
      throw ServiceError("片头片尾设置无效")
    }
    if let dynamicRegex, !dynamicRegex.isEmpty {
      _ = try NSRegularExpression(pattern: dynamicRegex, options: .caseInsensitive)
    }
    try typeface?.validate()
    guard (0...1000).contains(visualFPS ?? 0) else { throw ServiceError("刷新率设置无效") }
    try layout?.validate()
    try danmakuStyle?.validate()
    try controls?.validate()
    try recommendation?.validate()
    try replyFilter?.validate()
    try networkMedia?.validate()
    try sponsorRules?.validate()
  }
  func apply(_ d: UserDefaults = .standard) throws {
    try validate()
    let encoder = JSONEncoder()
    let sponsorBytes = try encoder.encode((sponsorRules ?? .legacy(sponsorAuto)).padded())
    let mediaBytes = try encoder.encode(
      networkMedia ?? .legacy(video: quality, audio: audioQuality, codec: codec))
    let recommendationBytes = try recommendation.map(encoder.encode)
    let styleBytes = try danmakuStyle.map(encoder.encode)
    let replyBytes = try replyFilter.map(encoder.encode)
    let layoutBytes = try layout.map(encoder.encode)
    let fonts = typeface ?? .standard
    let fontBytes = try fonts.encoded()
    let speedBytes = try encoder.encode((speeds ?? SpeedPresets.defaults).sorted())
    d.set(sponsorBytes, forKey: SponsorRules.key)
    d.set(mediaBytes, forKey: NetworkMediaRules.key)
    if let recommendationBytes { d.set(recommendationBytes, forKey: RecommendationRules.key) }
    if let replyBytes { d.set(replyBytes, forKey: ReplyFilterRules.key) }
    if let styleBytes { d.set(styleBytes, forKey: DanmakuStyle.key) }
    if let layoutBytes { d.set(layoutBytes, forKey: NavigationLayout.key) }
    d.set(dynamicRegex ?? "", forKey: "social.dynamicRegex")
    d.set(hideGoods ?? false, forKey: "social.hideGoods")
    CustomTypefaces.restore(fonts)
    d.set(fontBytes, forKey: TypefaceChoice.key)
    d.set(visualFPS ?? 0, forKey: "display.fps")
    controls?.apply(d)
    d.set(speedBytes, forKey: SpeedPresets.key)
    d.set(diagnosticLog ?? true, forKey: DiagnosticJournal.key)
    d.set(hideLikeNotices ?? false, forKey: "inbox.hideLikes")
    d.set(episodeSkip ?? "once", forKey: "play.episodeSkip")
    d.set(videoSync ?? PresentationMode.system.rawValue, forKey: PresentationMode.modeKey)
    d.set(String(PresentationMode.validSmoothing(autosync ?? "0") ?? 0), forKey: PresentationMode.smoothingKey)
    d.set(quality ?? 0, forKey: "play.quality")
    d.set(audioQuality ?? 0, forKey: "play.audioQuality")
    d.set(codec ?? "auto", forKey: "play.codec")
    d.set(gravity ?? "fit", forKey: "play.gravity")
    d.set(subtitleSize ?? 16, forKey: "play.subtitleSize")
    d.set(dmSize ?? 15, forKey: "dm.fontSize")
    d.set(fullDmSize ?? 18, forKey: "dm.fullFontSize")
    d.set(sponsorEnabled ?? false, forKey: "sponsor.enabled")
    d.set(sponsorAuto ?? false, forKey: "sponsor.auto")
    d.set(sponsorServer ?? "https://www.bsbsb.top", forKey: "sponsor.server")
    if let guestDevice { d.set(guestDevice, forKey: MobileDeviceID.guestKey) }
    if let scrollSpring { d.set(scrollSpring, forKey: ScrollSpring.key) }
    d.set(normalizer ?? "0", forKey: "audio.normalization")
    d.set(fallbackNormalizer ?? "0", forKey: "audio.fallbackNormalization")
    d.set(decoderChoices, forKey: DecoderPreference.listKey)
    if let apiProxy { try apiProxy.save(d) }
    d.set(vodLine, forKey: VODLine.key)
    d.set(liveCDN.flatMap { LiveCDNOrigin($0)?.base.absoluteString }, forKey: "live.cdn")
    d.set(liveStream, forKey: "live.stream")
    d.set(listenRepeat ?? "顺序播放", forKey: "listen.repeat")
    d.set(appearance, forKey: "appearance")
    d.set(accent, forKey: "accent")
    d.set(themeSeed ?? ThemeSeeds.previous(accent), forKey: ThemeSeeds.seedKey)
    d.set(paletteStyle ?? 10, forKey: ThemeSeeds.styleKey)
    d.set(systemTint ?? false, forKey: ThemeSeeds.systemKey)
    d.set(rate, forKey: "play.rate")
    d.set(bullets, forKey: "video.danmaku.enabled")
    d.set(opacity, forKey: "dm.opacity")
    d.set(area, forKey: "dm.area")
    d.set(blocked, forKey: "dm.blocked")
    d.set(searchHistory, forKey: "search.save")
    d.set(historySync ?? true, forKey: "history.sync")
    d.set(remember ?? true, forKey: "play.remember")
  }
}
struct PreferencesFile: FileDocument {
  static var readableContentTypes: [UTType] { [.json] }
  var data: Data
  init(prefs: NativePrefs) throws {
    data = try prefs.archive()
  }
  init(configuration: ReadConfiguration) throws {
    guard let d = configuration.file.regularFileContents, d.count <= BackupFormat.limit else {
      throw ServiceError("不是有效的设置备份")
    }
    data = d
  }
  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: data)
  }
}
struct SettingsView: View {
  private let allowSplit: Bool
  @State private var selectedPane = SettingsPane.account
  @Environment(\.dynamicTypeSize) private var settingsTextSize
  @Environment(\.accessibilityVoiceOverEnabled) private var settingsVoiceOver
  init(allowSplit: Bool = true) { self.allowSplit = allowSplit }
  @AppStorage("discovery.pgcTimeline") private var timeline = true
  @AppStorage("creator.shop") private var shop = false
  @AppStorage("appearance") var appearance = "system"
  @AppStorage("accent") var accent = "rose"
  @AppStorage("play.remember") var remember = true
  @AppStorage("play.rate") var rate = 1.0
  @AppStorage(SpeedPresets.key) private var speedData = Data()
  @AppStorage("video.danmaku.enabled") var dm = true
  @AppStorage("dm.tap") private var tapDM = true
  @AppStorage("dm.opacity") var opacity = 1.0
  @AppStorage("dm.area") var area = 0.5
  @AppStorage("dm.blocked") var blocked = ""
  @AppStorage("inbox.hideLikes") private var hideLikes = false
  @AppStorage("vip.autoExperience") private var vipExperience = true
  @AppStorage("search.save") var search = true
  @AppStorage("search.hot") private var hot = true
  @AppStorage("search.defaultWord") private var defaultWord = false
  @AppStorage("search.picks") private var picks = true
  @AppStorage("search.suggest") private var suggestions = true
  @State private var exporting = false
  @State private var importing = false
  @State private var backup: PreferencesFile?
  @State private var restore: SettingsRestore?
  @State private var msg: String?
  @State private var filter = ""
  private var browsing: Bool { filter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  var body: some View {
    GeometryReader { proxy in
      if allowSplit && NavigationRules.splitSettings(width:proxy.size.width,height:proxy.size.height,accessibility:settingsVoiceOver || settingsTextSize.isAccessibilitySize) {
        SettingsWidePane(choice:$selectedPane,general:settingsForm)
      } else { settingsForm }
    }
  }
  private var settingsForm: some View {
    Form {
      if !browsing { NativeSettingsResults(query: filter) }
      if browsing {
        Section { SettingsAccountCard().settingAnchor("SettingsView/切换与退出账号") }
        Section("外观与布局") {
          Picker(selection: $appearance) {
            Text("跟随系统").tag("system")
            Text("浅色").tag("light")
            Text("深色").tag("dark")
          } label: { Label("外观模式", systemImage: "circle.lefthalf.filled").labelStyle(SettingsIconLabelStyle(color: .indigo)) }
            .settingAnchor("SettingsView/外观模式")
          NavigationLink { DeferredPage { ThemePicker() } } label: { Label("主题颜色", systemImage: "paintpalette.fill").labelStyle(SettingsIconLabelStyle(color: .pink)) }.settingAnchor("SettingsView/主题颜色")
          NavigationLink { DeferredPage { NavigationLayoutPanel() } } label: { Label("导航布局", systemImage: "rectangle.bottomthird.inset.filled").labelStyle(SettingsIconLabelStyle(color: .blue)) }.settingAnchor("SettingsView/导航布局")
          NavigationLink { DeferredPage { InteractionScaleOptions() } } label: { Label("界面与手势", systemImage: "hand.draw.fill").labelStyle(SettingsIconLabelStyle(color: .blue)) }.settingAnchor("SettingsView/界面与手势")
          NavigationLink { DeferredPage { TypographyPanel() } } label: { Label("字体与字号", systemImage: "textformat.size").labelStyle(SettingsIconLabelStyle(color: .indigo)) }.settingAnchor("SettingsView/字体与字号")
          NavigationLink { DeferredPage { DisplayPanel() } } label: { Label("刷新率", systemImage: "gauge.with.dots.needle.67percent").labelStyle(SettingsIconLabelStyle(color: .orange)) }.settingAnchor("SettingsView/刷新率")
        }
        Section("深色与阅读") { NightSettings() }
        Section("播放") {
          NavigationLink { DeferredPage { PlaybackEngineSettings() } } label: { Label("播放器内核", systemImage: "play.circle.fill").labelStyle(SettingsIconLabelStyle(color: .blue)) }.settingAnchor("SettingsView/播放器内核")
          NavigationLink { DeferredPage { PlaybackOptionsView() } } label: { Label("画面与音轨", systemImage: "play.rectangle.fill").labelStyle(SettingsIconLabelStyle(color: .blue)) }.settingAnchor("SettingsView/画面与音轨")
          NavigationLink { DeferredPage { HighQualityPlaybackSettings() } } label: { Label("高画质解析设置", systemImage: "sparkles.rectangle.stack.fill").labelStyle(SettingsIconLabelStyle(color: .purple)) }.settingAnchor("SettingsView/高画质解析设置")
          NavigationLink { DeferredPage { PlayerPreferencePanel() } } label: { Label("详情与播放控制", systemImage: "slider.horizontal.3").labelStyle(SettingsIconLabelStyle(color: .gray)) }.settingAnchor("SettingsView/详情与播放控制")
          Picker(selection: $rate) {
            ForEach(SpeedPresets.decode(speedData), id: \.self) { Text("\($0.formatted())×").tag($0) }
          } label: { Label("默认倍速", systemImage: "gauge.with.dots.needle.50percent").labelStyle(SettingsIconLabelStyle(color: .orange)) }
            .settingAnchor("SettingsView/默认倍速")
          NavigationLink { DeferredPage { SpeedSettings() } } label: { Label("自定义播放倍速", systemImage: "dial.medium.fill").labelStyle(SettingsIconLabelStyle(color: .orange)) }.settingAnchor("SettingsView/自定义播放倍速")
          Toggle(isOn: $remember) { Label("记住播放进度", systemImage: "bookmark.fill").labelStyle(SettingsIconLabelStyle(color: .blue)) }.settingAnchor("SettingsView/记住播放进度")
          NavigationLink { DeferredPage { SponsorSettings() } } label: { Label("空降助手", systemImage: "forward.end.fill").labelStyle(SettingsIconLabelStyle(color: .purple)) }.settingAnchor("SettingsView/空降助手")
        }
        Section("弹幕") {
          Toggle(isOn: $dm) { Label("显示弹幕", systemImage: "text.bubble.fill").labelStyle(SettingsIconLabelStyle(color: .teal)) }.settingAnchor("SettingsView/显示弹幕")
          SettingToggle(title: "点按弹幕时悬停", symbol: "hand.tap.fill", color: .teal, isOn: $tapDM)
            .settingAnchor("SettingsView/点按弹幕时悬停")
          SettingSlider(title: "弹幕不透明度", value: $opacity, range: 0...1, symbol: "circle.lefthalf.striped.horizontal", color: .teal)
            .settingAnchor("SettingsView/弹幕不透明度")
          SettingSlider(title: "滚动弹幕区域", value: $area, range: 0.1...1, step: 0.1, symbol: "rectangle.tophalf.filled", color: .teal)
            .settingAnchor("SettingsView/滚动弹幕区域")
          NavigationLink { DeferredPage { DanmakuStylePanel() } } label: { Label("弹幕样式与过滤", systemImage: "textformat").labelStyle(SettingsIconLabelStyle(color: .teal)) }.settingAnchor("SettingsView/弹幕样式与过滤")
          NavigationLink {
            SettingTextPage(title: "弹幕关键词屏蔽", footer: "每行一个关键词，弹幕包含任一关键词时不显示。", text: $blocked)
          } label: {
            HStack {
              Label("弹幕关键词屏蔽", systemImage: "line.3.horizontal.decrease").labelStyle(SettingsIconLabelStyle(color: .gray))
              Spacer()
              let n = blocked.split(whereSeparator: \.isNewline).filter { !$0.isEmpty }.count
              if n > 0 { Text("\(n) 个").foregroundStyle(.secondary) }
            }
          }.settingAnchor("SettingsView/弹幕关键词屏蔽")
        }
        Section("内容与提醒") {
          NavigationLink { DeferredPage { RecommendationSettings() } } label: { Label("推荐过滤", systemImage: "line.3.horizontal.decrease.circle.fill").labelStyle(SettingsIconLabelStyle(color: .orange)) }.settingAnchor("SettingsView/推荐过滤")
          NavigationLink { DeferredPage { ReplyFilterPanel() } } label: { Label("评论设置", systemImage: "bubble.left.fill").labelStyle(SettingsIconLabelStyle(color: .teal)) }.settingAnchor("SettingsView/评论设置")
          NavigationLink { DeferredPage { CommunityFilterPanel() } } label: { Label("动态筛选", systemImage: "person.2.fill").labelStyle(SettingsIconLabelStyle(color: .blue)) }.settingAnchor("SettingsView/动态筛选")
          NavigationLink { DeferredPage { GallerySettings() } } label: { Label("图片与实况照片", systemImage: "photo.fill").labelStyle(SettingsIconLabelStyle(color: .pink)) }.settingAnchor("SettingsView/图片与实况照片")
          NavigationLink { DeferredPage { SuperChatSettings() } } label: { Label("直播醒目留言", systemImage: "text.bubble.fill").labelStyle(SettingsIconLabelStyle(color: .purple)) }.settingAnchor("SettingsView/直播醒目留言")
          NavigationLink { DeferredPage { BadgePreferences() } } label: { Label("未读提醒", systemImage: "bell.badge.fill").labelStyle(SettingsIconLabelStyle(color: .red)) }.settingAnchor("SettingsView/未读提醒")
          SettingToggle(title: "隐藏收到的赞", symbol: "hand.thumbsup.fill", color: .pink, isOn: $hideLikes)
            .settingAnchor("SettingsView/隐藏收到的赞")
        }
        Section("番剧与空间") {
          SettingToggle(title: "番剧首页显示更新日历", symbol: "calendar", color: .red, isOn: $timeline)
            .settingAnchor("SettingsView/番剧首页显示更新日历")
          CreatorSectionPreference()
          SettingToggle(title: "空间显示 UP 主的小店", symbol: "bag.fill", color: .orange, isOn: $shop)
            .settingAnchor("SettingsView/空间显示 UP 主的小店")
        }
        Section {
          SettingToggle(title: "显示搜索默认词", symbol: "text.magnifyingglass", color: .blue, isOn: $defaultWord)
            .settingAnchor("SettingsView/显示搜索默认词")
          SettingToggle(title: "显示热搜", symbol: "flame.fill", color: .red, isOn: $hot)
            .settingAnchor("SettingsView/显示热搜")
          SettingToggle(title: "显示猜你想搜", symbol: "sparkles", color: .purple, isOn: $picks)
            .settingAnchor("SettingsView/显示猜你想搜")
          SettingToggle(title: "输入时显示搜索建议", symbol: "text.cursor", color: .gray, isOn: $suggestions)
            .settingAnchor("SettingsView/输入时显示搜索建议")
          SettingToggle(title: "保存搜索记录", symbol: "clock.arrow.circlepath", color: .gray, isOn: $search)
            .settingAnchor("SettingsView/保存搜索记录")
          Button(role: .destructive) {
            UserDefaults.standard.removeObject(forKey: "search.history")
            msg = "已清空搜索记录"
          } label: {
            Label("清空搜索记录", systemImage: "trash.fill").labelStyle(SettingsIconLabelStyle(color: .red))
          }.settingAnchor("SettingsView/清空搜索记录")
        } header: {
          Text("搜索")
        }
        Section {
          Toggle(isOn: $vipExperience) {
            Label("自动领取大会员经验", systemImage: "crown.fill")
              .labelStyle(SettingsIconLabelStyle(color: .orange))
          }.settingAnchor("SettingsView/自动领取大会员经验")
          NavigationLink { DeferredPage { DeviceIdentityPanel() } } label: { Label("客户端设备标识", systemImage: "iphone.gen3").labelStyle(SettingsIconLabelStyle(color: .gray)) }.settingAnchor("SettingsView/客户端设备标识")
        } header: {
          Text("账号与隐私")
        } footer: {
          Text("每天打开应用时为大会员账号领取一次每日经验，成功后会提示。账号切换与退出在顶部的账号卡片里。")
        }
        Section("存储与备份") {
          NavigationLink { DeferredPage { ArtworkCacheSettings() } } label: { Label("图片缓存", systemImage: "photo.stack.fill").labelStyle(SettingsIconLabelStyle(color: .pink)) }.settingAnchor("SettingsView/图片缓存")
          NavigationLink { DeferredPage { WebBackup() } } label: { Label("WebDAV 备份", systemImage: "icloud.fill").labelStyle(SettingsIconLabelStyle(color: .blue)) }.settingAnchor("SettingsView/WebDAV 备份")
          NavigationLink { DeferredPage { DataPackPanel() } } label: { Label("本地数据包", systemImage: "externaldrive.fill").labelStyle(SettingsIconLabelStyle(color: .gray)) }.settingAnchor("SettingsView/本地数据包")
          Button {
            Task {
              do {
                backup = try await Task.detached(priority: .userInitiated) {
                  try PreferencesFile(prefs: .current())
                }.value
                exporting = true
              } catch { msg = error.localizedDescription }
            }
          } label: { Label("导出设置", systemImage: "square.and.arrow.up").labelStyle(SettingsIconLabelStyle(color: .blue)) }
            .settingAnchor("SettingsView/导出设置")
          Button { importing = true } label: { Label("从文件恢复", systemImage: "square.and.arrow.down").labelStyle(SettingsIconLabelStyle(color: .blue)) }
            .settingAnchor("SettingsView/从文件恢复")
        }
        Section("连接与支持") {
          NavigationLink { DeferredPage { ConnectionSettings() } } label: { Label("网络连接", systemImage: "network").labelStyle(SettingsIconLabelStyle(color: .blue)) }.settingAnchor("SettingsView/网络连接")
          NavigationLink { DeferredPage { DiagnosticView() } } label: { Label("诊断日志", systemImage: "waveform.path.ecg").labelStyle(SettingsIconLabelStyle(color: .gray)) }.settingAnchor("SettingsView/诊断日志")
          NavigationLink { DeferredPage { VersionPanel() } } label: { Label("版本与更新", systemImage: "arrow.down.app.fill").labelStyle(SettingsIconLabelStyle(color: .blue)) }.settingAnchor("SettingsView/版本与更新")
        }
        Section {
          NavigationLink { DeferredPage { AboutPanel() } } label: { Label("关于与数据管理", systemImage: "info.circle.fill").labelStyle(SettingsIconLabelStyle(color: .gray)) }.settingAnchor("SettingsView/关于与数据管理")
          NavigationLink { DeferredPage { OpenSourceNotices() } } label: { Label("开源许可", systemImage: "doc.text.fill").labelStyle(SettingsIconLabelStyle(color: .gray)) }.settingAnchor("SettingsView/开源许可")
          Link(destination: UpstreamRelease.lilite) {
            Label("项目源码", systemImage: "chevron.left.forwardslash.chevron.right").labelStyle(SettingsIconLabelStyle(color: .gray))
          }
        } header: { Text("关于") } footer: {
          Text("轻哩 LiLite").frame(maxWidth: .infinity).padding(.vertical, 8)
        }
      }
    }.formStyle(.grouped).navigationTitle("设置").searchable(text: $filter, prompt: "搜索设置")
      .fileExporter(
        isPresented: $exporting, document: backup, contentType: .json,
        defaultFilename: "PiliNative-settings"
      ) { r in if case .failure(let e) = r { msg = e.localizedDescription } }
      .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
        Task {
          do {
            let u = try result.get()
            restore = try await Task.detached(priority: .userInitiated) {
              let granted = u.startAccessingSecurityScopedResource()
              defer { if granted { u.stopAccessingSecurityScopedResource() } }
              let size = try u.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
              guard size <= BackupFormat.limit else { throw ServiceError("文件过大") }
              return try SettingsRestore(Data(contentsOf: u, options: .mappedIfSafe))
            }.value
          } catch { msg = error.localizedDescription }
        }
      }
      .confirmationDialog(
        "覆盖当前设置？", isPresented: Binding(get: { restore != nil }, set: { if !$0 { restore = nil } }),
        presenting: restore
      ) { p in
        Button("恢复") {
          Task {
            do {
              try await Task.detached(priority: .userInitiated) { try p.apply() }.value
              msg = "已恢复设置"
            } catch { msg = error.localizedDescription }
          }
        }
      } message: { p in
        Text(p.summary)
      }
      .alert("设置", isPresented: Binding(get: { msg != nil }, set: { if !$0 { msg = nil } })) {
        Button("好") {}
      } message: {
        Text(msg ?? "")
      }
  }
}
