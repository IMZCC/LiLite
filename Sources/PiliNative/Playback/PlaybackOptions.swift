import AVFoundation
import SwiftUI

enum PlaybackOption {
  static let qualities = NetworkMediaRules.videoIDs, audio = NetworkMediaRules.audioIDs
  static let codecs = ["auto", "avc1", "hev1", "av01", "dvh1"]
  static func familyLabel(_ s: String) -> String {
    ["AVC": "H.264", "HEVC": "HEVC", "DVH1": "杜比视界", "AV1": "AV1"][s] ?? s
  }
  static func liveName(_ id: Int) -> String {
    [
      80: "流畅", 150: "高清", 250: "超清", 400: "蓝光", 10000: "原画", 15000: "2K", 20000: "4K",
      25000: "4K 原画", 30000: "杜比",
    ][id] ?? String(id)
  }
  static let modes = PictureFit.allCases.map(\.rawValue)
  static func codecName(_ c: String) -> String {
    ["auto": "自动", "avc1": "H.264", "hev1": "HEVC", "av01": "AV1"][c] ?? c
  }
  static func audioName(_ a: Int) -> String {
    [
      0: "自动", 30216: "标准", 30232: "较高", 30280: "高品质", 30250: "杜比全景声", 30255: "杜比全景声（高码率）",
      30251: "Hi-Res 无损",
    ][a] ?? "\(a)"
  }
  static func gravity(_ v: String) -> AVLayerVideoGravity {
    v == "fill" ? .resizeAspectFill : v == "stretch" ? .resize : .resizeAspect
  }
  static func preferredQuality(_ available: [Int]) -> Int? {
    let r = NetworkMediaRules.current()
    return NetworkMediaRules.target(
      available, target: MediaNetwork.shared.cellular ? r.cellVideo : r.wifiVideo, score: { $0 })
  }
  static func needsDash() -> Bool {
    let r = NetworkMediaRules.current()
    let cell = MediaNetwork.shared.cellular
    return (cell ? r.cellVideo : r.wifiVideo) != 0 || (cell ? r.cellAudio : r.wifiAudio) != 0
      || !r.codecOrder(cellular: cell).isEmpty
  }
  private static func supported(_ stream: DashStream, media: String) -> Bool {
    let c = stream.codecs
    guard
      !c.isEmpty
        && c.utf8.allSatisfy({
          (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            || [45, 46].contains($0)
        })
    else { return false }
    return AVURLAsset.isPlayableExtendedMIMEType(media + "/mp4; codecs=\"" + c + "\"")
  }
  static func supportsVideo(_ s: DashStream) -> Bool {
    !DecoderOptions.routes(s).isEmpty
  }
  static func supportsVideo(_ s: DashStream, engine: PlaybackEngineKind) -> Bool {
    if engine == .avplayer { return supportsVideo(s) }
    let codec = s.codecs.lowercased()
    return ["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe", "av01", "vp09", "vp9"].contains { codec.hasPrefix($0) }
  }
  static func supportsAudio(_ s: DashStream, engine: PlaybackEngineKind) -> Bool {
    if engine == .avplayer { return supportsAudio(s) }
    let codec = s.codecs.lowercased()
    return ["mp4a", "ac-3", "ec-3", "flac", "opus", "alac"].contains { codec.hasPrefix($0) }
  }
  static func supportsAudio(_ s: DashStream) -> Bool {
    s.codecs.hasPrefix("mp4a.40.") || supported(s, media: "audio")
  }
  static func supportsOfflineVideo(_ s: DashStream) -> Bool { supportsVideo(s) }
  static func chooseOfflineVideo(_ streams: [DashStream]) -> DashStream? {
    choose(streams.filter(supportsOfflineVideo))
  }
  static func chooseVideo(_ streams: [DashStream]) -> DashStream? {
    choose(streams.filter(supportsVideo))
  }
  static func chooseVideo(_ streams: [DashStream], engine: PlaybackEngineKind) -> DashStream? {
    choose(streams.filter { supportsVideo($0, engine: engine) })
  }
  private static func choose(_ options: [DashStream]) -> DashStream? {
    for f in NetworkMediaRules.current().codecOrder(cellular: MediaNetwork.shared.cellular) {
      if let stream = options.first(where: { NetworkMediaRules.family($0.codecs) == f }) {
        return stream
      }
    }
    return options.first
  }
  static func chooseAudio(_ streams: [DashStream], requested: Int? = nil, engine: PlaybackEngineKind = .avplayer) -> DashStream? {
    let options = streams.filter { supportsAudio($0, engine: engine) }
    let r = NetworkMediaRules.current()
    let id = requested ?? (MediaNetwork.shared.cellular ? r.cellAudio : r.wifiAudio)
    if let exact = options.first(where: { $0.id == id }) { return exact }
    return NetworkMediaRules.target(
      options, target: NetworkMediaRules.audioRank(id),
      score: { NetworkMediaRules.audioRank($0.id) })
  }
}
struct PlaybackOptionsView: View {
  @AppStorage(ArchiveStreamGrant.guestHD) private var guestHD = true
  @AppStorage("play.episodeSkip") private var episodeSkip = EpisodeSkipMode.once.rawValue
  @AppStorage("play.gravity") private var gravity = "fit"
  @AppStorage("play.subtitleSize") private var subtitle = 16.0
  @AppStorage("dm.fontSize") private var bullet = 15.0
  @AppStorage("dm.fullFontSize") private var full = 18.0
  var body: some View {
    Form {
      NavigationLink("播放器内核") { PlaybackEngineSettings() }.settingAnchor("PlaybackOptionsView/播放器内核")
      Picker("番剧片头片尾", selection: $episodeSkip) {
        ForEach(EpisodeSkipMode.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
      }.settingAnchor("PlaybackOptionsView/番剧片头片尾")
      Toggle("游客播放优先使用可用的 1080P", isOn: $guestHD).settingAnchor("PlaybackOptionsView/游客播放优先使用可用的 1080P")
      NavigationLink("视频解码") { DecoderSettings() }.settingAnchor("PlaybackOptionsView/视频解码")
      NavigationLink("Wi-Fi 与有线网络") { MediaProfilePanel(cellular: false) }.settingAnchor("PlaybackOptionsView/Wi-Fi 与有线网络")
      NavigationLink("蜂窝网络") { MediaProfilePanel(cellular: true) }.settingAnchor("PlaybackOptionsView/蜂窝网络")
      Picker("视频比例", selection: $gravity) {
        ForEach(PictureFit.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
      }.settingAnchor("PlaybackOptionsView/视频比例")
      MediaTextScaleControl(title: "字幕字号", points: $subtitle, base: 16)
      MediaTextScaleControl(title: "弹幕字号", points: $bullet)
      MediaTextScaleControl(title: "全屏弹幕字号", points: $full)
    }.navigationTitle("画面与音轨")
  }
}
