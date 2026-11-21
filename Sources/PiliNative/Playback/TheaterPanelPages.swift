import AVFoundation
import CoreMedia
import SwiftUI
import UniformTypeIdentifiers

// The settings pages the fullscreen 更多 panel opens, drawn with the panel's own parts
// (TheaterPanelKit) instead of the app's grouped forms. They change the same stored settings as
// those forms, and apply at once: there is no 保存 to press.

// MARK: - 定时关闭

struct TheaterPanelSleep: View {
  @ObservedObject private var timer = PlaybackSleepTimer.shared
  @AppStorage("sleep.lastMinutes") private var chosen = 0
  @AppStorage("sleep.waitItem") private var wait = false
  @AppStorage("sleep.action") private var actionRaw = PlaybackSleepTimer.FinishAction.pause.rawValue
  @State private var custom = false
  @State private var minutes = 30.0
  private var running: Bool { timer.state != .off }
  private static func label(_ m: Int) -> String {
    if m == 0 { return "不开启" }
    let h = m / 60, r = m % 60
    return h > 0 && r > 0 ? "\(h)小时\(r)分" : h > 0 ? "\(h)小时" : "\(r)分钟"
  }
  var body: some View {
    TheaterPanelScroll(title: "定时关闭") {
      if running {
        HStack(spacing: 8) {
          Image(systemName: "hourglass")
          switch timer.state {
          case .scheduled(let end, _): Text("剩余 ") + Text(end, style: .timer).monospacedDigit()
          case .finishingItem: Text("本集播完后停止")
          case .off: EmptyView()
          }
        }
        .font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.accentColor)
        .padding(.horizontal, 16).padding(.top, 12)
      }
      TheaterPanelSection("时长") {
        let lengths = Array(Set([0, 15, 30, 45, 60, chosen])).sorted()
        WrappingActions(spacing: 8, rowSpacing: 8) {
          ForEach(lengths, id: \.self) { m in
            TheaterPanelChip(name: Self.label(m), on: !custom && (running ? chosen : 0) == m) { start(m) }
          }
          TheaterPanelChip(name: "自定义", on: custom) {
            TouchFeedback.light()
            minutes = Double(chosen > 0 ? chosen : 30)
            custom.toggle()
          }
        }
      }
      if custom {
        TheaterPanelSlider(title: "自定义时长", value: $minutes, range: 5...240, step: 5) { Self.label(Int($0)) }
        Button {
          custom = false
          start(Int(minutes))
        } label: {
          Text("开始计时").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Color.accentColor, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PlayerPressStyle())
        .padding(.horizontal, 16).padding(.top, 6).padding(.bottom, 10)
      }
      TheaterPanelDivider()
      TheaterPanelSwitch(title: "额外等待视频播放完毕", on: $wait)
      TheaterPanelDivider()
      TheaterPanelSection("倒计时结束后") {
        TheaterPanelChoices(options: PlaybackSleepTimer.FinishAction.allCases.map { ($0.rawValue, $0.rawValue) },
          selected: actionRaw) { actionRaw = $0 }
      }
    }
    .animation(.easeOut(duration: 0.2), value: custom)
    .animation(.easeOut(duration: 0.2), value: running)
  }
  private func start(_ m: Int) {
    TouchFeedback.light()
    custom = false
    if m <= 0 {
      timer.cancel()
    } else {
      chosen = m
      timer.schedule(minutes: m, afterItem: wait,
        action: PlaybackSleepTimer.FinishAction(rawValue: actionRaw) ?? .pause)
    }
  }
}

// MARK: - 字幕

struct TheaterPanelSubtitles: View {
  @ObservedObject var session: SubtitleSession
  var refresh: (() -> Void)?
  @State private var importing = false
  @State private var working = false
  @State private var message: String?
  var body: some View {
    TheaterPanelScroll(title: "字幕") {
      TheaterPanelSection("字幕") {
        TheaterPanelChoices(options: [(nil as String?, "关闭")] + session.tracks.map { (Optional($0.id), $0.name) },
          selected: session.first) { id in choose(id, secondary: false) }
      }
      if session.tracks.isEmpty {
        TheaterPanelNote("这个视频没有可用字幕，可以加载本地字幕文件")
      }
      if session.first != nil, session.tracks.count > 1 {
        TheaterPanelDivider()
        TheaterPanelSection("第二字幕") {
          TheaterPanelChoices(
            options: [(nil as String?, "不显示")] + session.tracks.filter { $0.id != session.first }.map { (Optional($0.id), $0.name) },
            selected: session.second) { id in choose(id, secondary: true) }
        }
      }
      TheaterPanelDivider()
      TheaterPanelAction(symbol: "doc.badge.plus", title: "加载字幕文件", value: working ? "载入中" : nil) {
        importing = true
      }
      .disabled(working)
      if let refresh {
        TheaterPanelAction(symbol: "arrow.clockwise", title: "刷新字幕列表") {
          TouchFeedback.light()
          refresh()
        }
      }
      TheaterPanelNote("支持 " + SubtitleFileFormat.allCases.map { $0.rawValue.uppercased() }.joined(separator: "、"))
      if let issue = message ?? session.issue {
        TheaterPanelNote(issue, warning: true)
      }
    }
    .animation(.easeOut(duration: 0.2), value: session.first)
    .fileImporter(isPresented: $importing, allowedContentTypes: SubtitleImport.types) { answer in
      do {
        let url = try answer.get()
        Task {
          working = true
          defer { working = false }
          do {
            try await SubtitleImport.load(url, into: session)
            message = nil
          } catch { if !Task.isCancelled { message = error.localizedDescription } }
        }
      } catch {
        if (error as NSError).code != NSUserCancelledError { message = error.localizedDescription }
      }
    }
  }
  private func choose(_ id: String?, secondary: Bool) {
    Task { await session.select(id, secondary: secondary) }
  }
}

// MARK: - 弹幕设置

/// The bullets' look and filters, applied as they change (the settings form saves on 保存).
struct TheaterPanelBullets: View {
  @State private var s = DanmakuStyle.decode(UserDefaults.standard.data(forKey: DanmakuStyle.key) ?? Data())
  @AppStorage("dm.fontSize") private var normal = 15.0
  @AppStorage("dm.fullFontSize") private var full = 18.0
  @AppStorage("dm.opacity") private var opacity = 1.0
  @AppStorage("dm.area") private var area = 0.5
  @State private var issue: String?
  private static let base = 15.0
  private func scale(_ points: Binding<Double>) -> Binding<Double> {
    Binding(get: { min(2.5, max(0.5, points.wrappedValue / Self.base)) },
      set: { points.wrappedValue = (($0 * 20).rounded() / 20) * Self.base })
  }
  private static func percent(_ v: Double) -> String { Int((v * 100).rounded()).formatted() + "%" }
  var body: some View {
    TheaterPanelScroll(title: "弹幕设置") {
      TheaterPanelSection("按类型屏蔽") {
        TheaterPanelFlags(options: [("滚动", $s.hideScroll), ("顶部", $s.hideTop), ("底部", $s.hideBottom), ("特殊", $s.hideSpecial)])
      }
      TheaterPanelSection("其他") {
        TheaterPanelFlags(options: [
          ("合并重复", $s.merge), ("等速滚动", $s.fixedVelocity), ("固定转滚动", $s.convertFixed),
          ("密集重叠", $s.dense), ("普通弹幕为白色", $s.monochrome), ("会员渐变色", $s.showVIP),
        ])
      }
      TheaterPanelDivider()
      VStack(spacing: 6) {
        TheaterPanelSlider(title: "智能屏蔽", value: $s.minimumWeight.asDouble, range: 0...11, step: 1) { "\(Int($0)) 级" }
        TheaterPanelSlider(title: "不透明度", value: $opacity, range: 0...1, step: 0.01, text: Self.percent)
        TheaterPanelSlider(title: "显示区域", value: $area, range: 0.1...1, step: 0.1, text: Self.percent)
        TheaterPanelSlider(title: "全屏字号", value: scale($full), range: 0.5...2.5, step: 0.05, text: Self.percent)
        TheaterPanelSlider(title: "普通字号", value: scale($normal), range: 0.5...2.5, step: 0.05, text: Self.percent)
        TheaterPanelSlider(title: "字重", value: $s.fontWeight.asDouble, range: 1...9, step: 1) { "\(Int($0))" }
        TheaterPanelSlider(title: "描边", value: $s.stroke, range: 0...5, step: 0.5) { $0.formatted() }
        TheaterPanelSlider(title: "行高", value: $s.lineHeight, range: 0.8...3, step: 0.1) {
          $0.formatted(.number.precision(.fractionLength(1)))
        }
        TheaterPanelSlider(title: "滚动时长", value: $s.duration, range: 1...20, step: 0.5) { $0.formatted() + " 秒" }
        TheaterPanelSlider(title: "固定时长", value: $s.staticDuration, range: 1...20, step: 0.5) { $0.formatted() + " 秒" }
      }
      .padding(.vertical, 8)
      TheaterPanelNote("智能屏蔽：权重低于设定值的弹幕不显示，数值越高过滤越多。屏蔽正则与发送者在 设置 › 弹幕 中编辑。")
      if let issue { TheaterPanelNote(issue, warning: true) }
    }
    .onChange(of: s) { _, value in
      do { try value.save(); issue = nil } catch { issue = error.localizedDescription }
    }
  }
}

// MARK: - 解码格式

struct TheaterPanelDecoder: View {
  @AppStorage(DecoderPreference.enabledKey) private var hardware = true
  @AppStorage(DecoderPreference.listKey) private var raw = "auto"
  private var ordered: [String] {
    (DecoderPreference.choices(raw) ?? ["auto"]).filter(DecoderPreference.local.contains)
  }
  private func write(_ value: [String]) {
    TouchFeedback.light()
    raw = value.isEmpty ? "auto" : value.joined(separator: ",")
  }
  static func label(_ s: String) -> String {
    [
      "auto": "自动", "auto-safe": "优先兼容", "auto-copy": "自动（拷贝）", "videotoolbox": "VideoToolbox 直通",
      "videotoolbox-copy": "VideoToolbox 拷贝", "no": "软件解码",
    ][s] ?? s
  }
  var body: some View {
    TheaterPanelScroll(title: "解码格式") {
      TheaterPanelSwitch(symbol: "cpu", title: "使用硬件解码", on: $hardware)
      TheaterPanelNote("关闭后全部使用软件解码，耗电更多")
      if hardware {
        TheaterPanelDivider()
        TheaterPanelSection("优先顺序") {
          VStack(spacing: 0) {
            ForEach(Array(ordered.enumerated()), id: \.element) { index, id in
              HStack(spacing: 12) {
                Text("\(index + 1)").font(.system(size: 12, weight: .bold).monospacedDigit())
                  .frame(width: 22, height: 22)
                  .background(Color.accentColor.opacity(index == 0 ? 1 : 0.35), in: Circle())
                Text(Self.label(id)).font(.system(size: 14))
                Spacer(minLength: 8)
                if index > 0 {
                  Button {
                    var v = ordered
                    v.swapAt(index, index - 1)
                    write(v)
                  } label: {
                    Image(systemName: "arrow.up").font(.system(size: 13, weight: .semibold))
                      .frame(width: 34, height: 34).contentShape(Rectangle())
                  }
                  .accessibilityLabel("提前 " + Self.label(id))
                }
                if ordered.count > 1 {
                  Button {
                    write(ordered.filter { $0 != id })
                  } label: {
                    Image(systemName: "minus.circle").font(.system(size: 15))
                      .foregroundStyle(.white.opacity(0.6))
                      .frame(width: 34, height: 34).contentShape(Rectangle())
                  }
                  .accessibilityLabel("移除 " + Self.label(id))
                }
              }
              .frame(minHeight: 40)
            }
          }
          .buttonStyle(PlayerPressStyle())
        }
        let rest = DecoderPreference.local.filter { !ordered.contains($0) }
        if !rest.isEmpty {
          TheaterPanelSection("添加") {
            WrappingActions(spacing: 8, rowSpacing: 8) {
              ForEach(rest, id: \.self) { id in
                TheaterPanelChip(name: Self.label(id), on: false) { write(ordered + [id]) }
              }
            }
          }
        }
        TheaterPanelNote("依次尝试直到成功解码")
      }
      TheaterPanelDivider()
      TheaterPanelAction(symbol: "arrow.uturn.backward", title: "恢复默认") {
        TouchFeedback.light()
        hardware = true
        raw = "auto"
      }
      .disabled(hardware && raw == "auto")
    }
    .animation(.easeOut(duration: 0.2), value: hardware)
    .animation(.easeOut(duration: 0.2), value: raw)
  }
}

// MARK: - 播放器内核

struct TheaterPanelEngine: View {
  @AppStorage(PlaybackEngineKind.key) private var selected = PlaybackEngineKind.mpv.rawValue
  var body: some View {
    TheaterPanelScroll(title: "播放器内核") {
      VStack(spacing: 0) {
        ForEach(PlaybackEngineKind.allCases, id: \.self) { kind in
          TheaterPanelPick(title: kind.title,
            detail: kind == .mpv ? "与原版同款内核，支持更多解码格式与倍速" : "系统播放器，另支持隔空播放",
            on: selected == kind.rawValue) {
              guard selected != kind.rawValue else { return }
              TouchFeedback.light()
              selected = kind.rawValue
            }
        }
      }
      .padding(.top, 6)
      TheaterPanelNote("两种内核均支持画中画与投屏，重新进入视频后生效")
    }
  }
}

// MARK: - 播放器音量

struct TheaterPanelVolume: View {
  @AppStorage("audio.gainPercent") private var gain = 100.0
  @AppStorage("audio.normalization") private var normal = "0"
  @AppStorage("audio.fallbackNormalization") private var fallback = "0"
  private static let modes = [("0", "关闭"), ("1", "动态均衡"), ("2", "响度标准化")]
  var body: some View {
    TheaterPanelScroll(title: "播放器音量") {
      TheaterPanelSlider(title: "播放器增益", value: $gain, range: 100...300, step: 5) { "\(Int($0))%" }
        .padding(.top, 8)
      if gain != 100 {
        TheaterPanelAction(symbol: "arrow.uturn.backward", title: "恢复 100%") {
          TouchFeedback.light()
          gain = 100
        }
      }
      TheaterPanelDivider().padding(.top, 6)
      TheaterPanelSection("音量均衡") {
        TheaterPanelChoices(options: Self.modes, selected: normal) { normal = $0 }
      }
      if !["0", "1", "2"].contains(normal) {
        TheaterPanelNote("正在使用自定义滤镜，可在 设置 › 播放 中修改")
      }
      if normal == "2" || normal.contains("loudnorm") {
        TheaterPanelSection("无响度数据时") {
          TheaterPanelChoices(options: Self.modes, selected: fallback) { fallback = $0 }
        }
      }
    }
    .animation(.easeOut(duration: 0.2), value: gain == 100)
    .animation(.easeOut(duration: 0.2), value: normal)
  }
}

// MARK: - 播放信息

struct TheaterPanelInfo: View {
  let player: any PlaybackEngine
  @ObservedObject var model: PlayerModel
  @State private var current: AnyObject?
  @State private var tracks: [String] = []
  var body: some View {
    TheaterPanelScroll(title: "播放信息") {
      TheaterPanelSection("来源") {
        VStack(spacing: 0) {
          TheaterPanelValue(title: "画质", value: StreamQuality.name(model.quality))
          if let video = model.selectedVideoStream {
            TheaterPanelValue(title: "视频编码", value: video.codecs)
            if let fps = video.frameRate { TheaterPanelValue(title: "源帧率", value: fps.formatted() + " fps") }
            if video.bandwidth > 0 { TheaterPanelValue(title: "视频码率", value: String(video.bandwidth / 1000) + " kbps") }
          }
          if let audio = model.selectedAudioStream { TheaterPanelValue(title: "音频编码", value: audio.codecs) }
          if let name = model.spokenTracks.first(where: { $0.id == model.spokenLanguage })?.label {
            TheaterPanelValue(title: "音轨", value: name)
          }
          TheaterPanelValue(title: "解码路线", value: model.decoderName)
        }
        .padding(.horizontal, -16)
      }
      if current != nil {
        TheaterPanelDivider()
        TheaterPanelSection("播放状态") {
          TimelineView(.periodic(from: .now, by: 1)) { _ in
            VStack(spacing: 0) {
              TheaterPanelValue(title: "状态", value: player.timeControlStatus == .playing ? "播放中"
                : player.timeControlStatus == .paused ? "已暂停" : "缓冲中")
              let size = player.playbackSize
              if size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
                TheaterPanelValue(title: "画面尺寸", value: "\(Int(size.width)) × \(Int(size.height))")
              }
              let t = player.currentTime().seconds, d = player.playbackDuration
              if t.isFinite, d.isFinite { TheaterPanelValue(title: "进度", value: clockText(t) + " / " + clockText(d)) }
              TheaterPanelValue(title: "速度", value: player.defaultRate.formatted() + "×")
              TheaterPanelValue(title: "音量", value: player.isMuted ? "静音" : String(Int(player.presentationVolume * 100)) + "%")
              if let log = (current as? AVPlayerItem)?.accessLog()?.events.last {
                if log.observedBitrate.isFinite, log.observedBitrate > 0 {
                  TheaterPanelValue(title: "实测码率", value: "\(Int(log.observedBitrate / 1000)) kbps")
                }
                if log.numberOfStalls >= 0 { TheaterPanelValue(title: "缓冲次数", value: String(log.numberOfStalls)) }
                if log.numberOfDroppedVideoFrames >= 0 {
                  TheaterPanelValue(title: "丢帧", value: String(log.numberOfDroppedVideoFrames))
                }
              }
            }
          }
          .padding(.horizontal, -16)
        }
      }
      if !tracks.isEmpty {
        TheaterPanelDivider()
        TheaterPanelSection("输出轨道") {
          VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(tracks.enumerated()), id: \.offset) { _, line in
              Text(line).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).textSelection(.enabled)
            }
          }
        }
      }
    }
    .onReceive(player.itemPublisher) { current = $0 }
    .task(id: current.map(ObjectIdentifier.init)) {
      tracks = []
      guard let item = current as? AVPlayerItem else { return }
      let lines = await Self.trackLines(item)
      if !Task.isCancelled, item === player.playbackItem { tracks = lines }
    }
  }
  /// The decoded tracks as "视频 hvc1", "音频 mp4a · 48000 Hz · 2 声道".
  private static func trackLines(_ item: AVPlayerItem) async -> [String] {
    guard let streams = try? await item.asset.load(.tracks) else { return [] }
    var result: [String] = []
    for track in streams.prefix(16) {
      let kind = track.mediaType
      guard kind == .audio || kind == .video, let desc = try? await track.load(.formatDescriptions).first else { continue }
      let c = CMFormatDescriptionGetMediaSubType(desc)
      let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: c >> $0) }
      let codec = bytes.allSatisfy { (32...126).contains($0) }
        ? String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces) : String(format: "%08X", c)
      var line = (kind == .video ? "视频 " : "音频 ") + codec
      if kind == .audio, let info = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
        line += " · \(Int(info.mSampleRate)) Hz · \(info.mChannelsPerFrame) 声道"
      }
      result.append(line)
    }
    return result
  }
}
