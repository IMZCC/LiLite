import AVKit
import Darwin
import SwiftUI
import UIKit

// The fullscreen player's chrome: a status line and a header of white icons at the top, a thick
// progress bar with the times at its ends, then play / next on the left and word buttons on the
// right. 4K and 选集 open their cards under the bar; 倍速 is the system menu. Gesture feedback is
// a smoked-glass capsule at the top centre.

// MARK: - Slots

/// A bottom-right word button of the fullscreen player that opens a panel under the progress bar.
struct PlayerPanelSlot: Identifiable {
  let id: String
  let title: String
  let content: AnyView
}

private struct PlayerPanelDismissKey: EnvironmentKey {
  static let defaultValue: (@MainActor () -> Void)? = nil
}
extension EnvironmentValues {
  /// Closes the open fullscreen panel (a card was chosen).
  var playerPanelDismiss: (@MainActor () -> Void)? {
    get { self[PlayerPanelDismissKey.self] }
    set { self[PlayerPanelDismissKey.self] = newValue }
  }
}

enum PlayerChromeMotion {
  /// Controls fade in and out quickly, without sliding.
  static let fade = Animation.easeOut(duration: 0.18)
  /// The bar rises and a panel slides up under it.
  static let panel = Animation.spring(response: 0.36, dampingFraction: 0.86)
}

// MARK: - Stream description

/// The renditions as the format chip and the quality cards name them.
struct PlayerStreamInfo: Equatable {
  var quality: Int
  var videoCodecs: String?, videoRate: Int?, width: Int?, height: Int?, frameRate: Double?
  var audioID: Int?, audioCodecs: String?
  init(quality: Int) { self.quality = quality }
  /// The single-file MP4 the site serves by default: always H.264 with AAC.
  static func progressive(_ quality: Int) -> Self {
    var info = Self(quality: quality)
    info.videoCodecs = "avc1"
    info.audioCodecs = "mp4a"
    return info
  }
  init(quality: Int, video: DashStream, audio: DashStream?) {
    self.quality = quality
    videoCodecs = video.codecs
    videoRate = video.bandwidth > 0 ? video.bandwidth : nil
    width = video.width
    height = video.height
    frameRate = video.frameRate
    audioID = audio?.id
    audioCodecs = audio?.codecs
  }
  static func shortName(_ q: Int) -> String {
    StreamQuality.name(q).split(separator: " ").first.map(String.init) ?? StreamQuality.name(q)
  }
  /// "4K HDR10", "1080P", "杜比视界".
  var headline: String {
    switch quality {
    case 125: return "HDR10"
    case 126: return "杜比视界"
    case 129: return "HDR Vivid"
    default: return Self.shortName(quality)
    }
  }
  /// "HEVC 10bit", "AVC", "AV1".
  var codecName: String? {
    guard let raw = videoCodecs?.lowercased(), !raw.isEmpty else { return nil }
    let parts = raw.split(separator: ".")
    if raw.hasPrefix("dvh") || raw.hasPrefix("dva") { return "杜比视界" }
    if raw.hasPrefix("hev") || raw.hasPrefix("hvc") {
      return parts.count > 1 && parts[1] == "2" ? "HEVC 10bit" : "HEVC"
    }
    if raw.hasPrefix("av01") { return parts.count > 3 && parts[3] == "10" ? "AV1 10bit" : "AV1" }
    if raw.hasPrefix("avc") { return "AVC" }
    return String(parts.first ?? "")
  }
  /// "9.84 Mbps".
  var rateText: String? {
    guard let videoRate else { return nil }
    let mbps = Double(videoRate) / 1_000_000
    return mbps.formatted(.number.precision(.fractionLength(mbps < 10 ? 2 : 1))) + " Mbps"
  }
  /// "3840×2160 · 60fps".
  var frameText: String? {
    var parts: [String] = []
    if let width, let height { parts.append("\(width)×\(height)") }
    if let frameRate { parts.append(Int(frameRate.rounded()).formatted() + "fps") }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }
  var audioName: String? {
    guard let raw = audioCodecs?.lowercased(), !raw.isEmpty else { return nil }
    if raw.hasPrefix("mp4a") { return "AAC" }
    if raw.hasPrefix("ec-3") || raw.hasPrefix("ec3") { return "E-AC-3" }
    if raw.hasPrefix("flac") || raw.hasPrefix("fla") { return "FLAC" }
    if raw.hasPrefix("opus") { return "Opus" }
    return raw.uppercased()
  }
  var audioDetail: String? { audioID.map(PlaybackOption.audioName) }
}

/// The glass chip under the title after a stream starts: quality and range, codec and rate, then
/// the audio track.
struct PlayerFormatChip: View {
  let info: PlayerStreamInfo
  var body: some View {
    HStack(spacing: 12) {
      Image(systemName: "dot.radiowaves.forward")
        .font(.system(size: 15, weight: .bold))
        .frame(width: 30, height: 30)
        .background(.white.opacity(0.92), in: Circle()).foregroundStyle(.black)
      VStack(alignment: .leading, spacing: 1) {
        Text(info.headline).font(.system(size: 15, weight: .semibold))
        if let detail = [info.codecName, info.rateText].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
          Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
        }
      }
      if let audio = info.audioName {
        Rectangle().fill(.white.opacity(0.25)).frame(width: 1, height: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text(audio).font(.system(size: 15, weight: .semibold))
          if let detail = info.audioDetail {
            Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.7))
          }
        }
      }
    }
    .foregroundStyle(.white).lineLimit(1)
    .padding(.leading, 8).padding(.trailing, 18).padding(.vertical, 6)
    .piliGlass(in: Capsule(), fallback: AnyShapeStyle(Color.black.opacity(0.45)))
    .environment(\.colorScheme, .dark)
    .accessibilityElement(children: .combine)
  }
}
private extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Glyphs

/// A header icon: every symbol fitted into the same 23 pt box and centred in a 44 pt cell, so
/// wide and round symbols line up on one centre line at one visual size.
struct PlayerToolGlyph: View {
  let symbol: String
  var dimmed = false
  static let box: CGFloat = 23
  var body: some View {
    Image(systemName: symbol)
      .resizable().scaledToFit()
      .font(.system(size: 20, weight: .medium))
      .frame(width: Self.box, height: Self.box)
      .foregroundStyle(.white.opacity(dimmed ? 0.5 : 1))
      .frame(width: 44, height: 44)
      .contentShape(Rectangle())
      .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
      .contentTransition(.symbolEffect(.replace))
  }
}

/// "弹" in a ring, struck through while the bullets are off.
struct PlayerBulletGlyph: View {
  let on: Bool
  var body: some View {
    ZStack {
      Circle().strokeBorder(.white, lineWidth: 1.6)
        .frame(width: PlayerToolGlyph.box, height: PlayerToolGlyph.box)
      Text("弹").font(.system(size: 11.5, weight: .semibold))
      if !on {
        Capsule().fill(.white).frame(width: 1.6, height: PlayerToolGlyph.box + 3).rotationEffect(.degrees(-45))
      }
    }
    .foregroundStyle(.white).opacity(on ? 1 : 0.6)
    .frame(width: 44, height: 44).contentShape(Rectangle())
    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    .animation(.easeOut(duration: 0.15), value: on)
  }
}

/// A bottom-right word button ("4K", "选集", "倍速").
struct PlayerWordGlyph: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.system(size: 16, weight: .semibold)).monospacedDigit()
      .foregroundStyle(.white).lineLimit(1)
      .padding(.horizontal, 10).frame(minWidth: 44, minHeight: 44)
      .contentShape(Rectangle())
      .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
      .contentTransition(.numericText())
  }
}

/// AirPlay: the header's own glyph, with the system route picker invisible on top to take the tap
/// (its built-in icon has its own size and would sit off the row's line).
struct PlayerRoutePicker: View {
  var body: some View {
    PlayerToolGlyph(symbol: "airplayvideo")
      .overlay { RoutePickerTarget().frame(width: 44, height: 44) }
  }
}
private struct RoutePickerTarget: UIViewRepresentable {
  func makeUIView(context: Context) -> AVRoutePickerView {
    let v = AVRoutePickerView()
    v.tintColor = .clear
    v.activeTintColor = .clear
    v.prioritizesVideoDevices = true
    v.backgroundColor = .clear
    return v
  }
  func updateUIView(_ v: AVRoutePickerView, context: Context) {}
}

// MARK: - Status line

/// Bytes received over Wi-Fi and cellular per second, sampled once a second while shown.
@MainActor final class NetworkRateMeter: ObservableObject {
  static let shared = NetworkRateMeter()
  @Published private(set) var bytesPerSecond = 0.0
  private var timer: Timer?
  private var users = 0
  private var last: (bytes: UInt64, at: TimeInterval)?
  func begin() {
    users += 1
    guard timer == nil else { return }
    last = nil
    sample()
    let t = Timer(timeInterval: 1, repeats: true) { _ in MainActor.assumeIsolated { NetworkRateMeter.shared.sample() } }
    RunLoop.main.add(t, forMode: .common)
    timer = t
  }
  func end() {
    users = max(0, users - 1)
    guard users == 0 else { return }
    timer?.invalidate()
    timer = nil
  }
  private func sample() {
    let bytes = Self.receivedBytes()
    let now = ProcessInfo.processInfo.systemUptime
    if let last, now > last.at {
      // The interface counters are 32 bit and wrap.
      let delta = bytes >= last.bytes ? bytes - last.bytes : bytes + (1 << 32) - last.bytes
      bytesPerSecond = Double(delta) / (now - last.at)
    }
    last = (bytes, now)
  }
  var text: String {
    let k = bytesPerSecond / 1024
    if k < 1000 { return Int(k.rounded()).formatted() + " KB/s" }
    return (k / 1024).formatted(.number.precision(.fractionLength(1))) + " MB/s"
  }
  nonisolated static func receivedBytes() -> UInt64 {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return 0 }
    defer { freeifaddrs(head) }
    var total: UInt64 = 0
    var cursor: UnsafeMutablePointer<ifaddrs>? = first
    while let node = cursor {
      let entry = node.pointee
      if let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
        let data = entry.ifa_data
      {
        let name = String(cString: entry.ifa_name)
        if name.hasPrefix("en") || name.hasPrefix("pdp_ip") {
          total += UInt64(data.assumingMemoryBound(to: if_data.self).pointee.ifi_ibytes)
        }
      }
      cursor = entry.ifa_next
    }
    return total
  }
}

/// The player's own status line: the time on the left; battery, network rate and the battery
/// glyph on the right.
struct PlayerStatusRow: View {
  @ObservedObject private var meter = NetworkRateMeter.shared
  @AppStorage("theater.battery") private var showsBattery = true
  @State private var token = UUID()
  @State private var level: Int?
  @State private var charging = false
  var body: some View {
    HStack(spacing: 12) {
      TimelineView(.periodic(from: Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970 / 60) * 60), by: 60)) { tick in
        let c = Calendar.current.dateComponents([.hour, .minute], from: tick.date)
        Text(String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0))
      }
      Spacer(minLength: 0)
      if showsBattery, let level {
        HStack(spacing: 3) {
          if charging { Image(systemName: "bolt.circle.fill").foregroundStyle(.green) }
          Text("\(level)%").foregroundStyle(charging ? Color.green : Color.white)
        }
      }
      Text(meter.text)
      if showsBattery, let level {
        Image(systemName: charging ? "battery.100percent.bolt" : Self.battery(level))
          .symbolRenderingMode(.palette)
          .foregroundStyle(charging ? Color.green : Color.white, .white.opacity(0.5))
      }
    }
    .font(.system(size: 14, weight: .semibold).monospacedDigit())
    .foregroundStyle(.white).lineLimit(1)
    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    .frame(height: 24)
    .onAppear {
      meter.begin()
      BatteryLease.begin(token)
      read()
    }
    .onDisappear {
      meter.end()
      BatteryLease.end(token)
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryLevelDidChangeNotification)) { _ in read() }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.batteryStateDidChangeNotification)) { _ in read() }
    .accessibilityHidden(true)
  }
  private func read() {
    let device = UIDevice.current
    let raw = device.batteryLevel
    level = raw >= 0 && raw <= 1 ? Int((raw * 100).rounded()) : nil
    charging = device.batteryState == .charging || device.batteryState == .full
  }
  private static func battery(_ level: Int) -> String {
    level < 15 ? "battery.0percent" : level < 38 ? "battery.25percent"
      : level < 63 ? "battery.50percent" : level < 88 ? "battery.75percent" : "battery.100percent"
  }
}

// MARK: - Progress

/// The fullscreen progress row: the time, a 6 pt white bar with the buffered span lighter and no
/// thumb, then the length. Dragging anywhere on it scrubs; the frame shows in the big preview.
struct FullscreenSeekBar: View {
  let clock: ViewportClock
  @ObservedObject var readout: ViewportReadout
  let seek: (Double) -> Void
  let editing: (Bool) -> Void
  var external: Double?
  var marks: AnyView?
  @Binding var scrub: Double?
  /// The inline player's smaller version: 12 pt times and a 4 pt bar.
  var compact = false
  private var time: Double { scrub ?? external ?? readout.seconds }
  var body: some View {
    HStack(spacing: compact ? 10 : 12) {
      Text(clockText(time)).frame(minWidth: compact ? 34 : 42, alignment: .leading)
      GeometryReader { g in
        let w = max(1, g.size.width)
        let total = max(0.01, clock.duration)
        let fraction = min(1, max(0, time / total))
        let height: CGFloat = compact ? (scrub == nil ? 4 : 6) : (scrub == nil ? 6 : 8)
        ZStack(alignment: .leading) {
          Rectangle().fill(.white.opacity(0.24))
          ForEach(readout.buffers.indices, id: \.self) { i in
            let span = readout.buffers[i]
            let lo = min(1, max(0, span.lowerBound / total)), hi = min(1, max(0, span.upperBound / total))
            Rectangle().fill(.white.opacity(0.42)).frame(width: max(0, hi - lo) * w).offset(x: lo * w)
          }
          Rectangle().fill(.white).frame(width: fraction * w)
          if let marks { marks.frame(width: w, height: height).allowsHitTesting(false) }
        }
        .frame(width: w, height: height)
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { v in
            guard clock.duration > 0 else { return }
            if scrub == nil { TouchFeedback.light(); editing(true) }
            scrub = min(1, max(0, v.location.x / w)) * clock.duration
          }.onEnded { v in
            if clock.duration > 0 { seek(min(1, max(0, v.location.x / w)) * clock.duration) }
            scrub = nil
            editing(false)
          })
        .animation(.easeOut(duration: 0.15), value: scrub == nil)
      }
      .frame(height: compact ? 28 : 32)
      Text(clockText(clock.duration)).frame(minWidth: compact ? 34 : 42, alignment: .trailing)
    }
    .font(.system(size: compact ? 12 : 14, weight: .semibold).monospacedDigit())
    .foregroundStyle(.white)
    .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    .accessibilityElement(children: .ignore).accessibilityLabel("播放进度")
    .accessibilityValue(clockText(time) + "，共" + clockText(clock.duration))
    .accessibilityAdjustableAction { direction in
      guard clock.duration > 0 else { return }
      let step = max(1, UserDefaults.standard.object(forKey: "player.seekStep") as? Double ?? 10)
      seek(min(clock.duration, max(0, time + (direction == .increment ? step : -step))))
    }
    .onDisappear {
      if scrub != nil {
        scrub = nil
        editing(false)
      }
    }
  }
}

// MARK: - Gesture feedback

/// Smoked glass capsule at the top centre for seek, level and speed feedback.
struct PlayerHUDCapsule<Content: View>: View {
  var tint: Color? = nil
  @ViewBuilder let content: () -> Content
  var body: some View {
    content()
      .foregroundStyle(.white)
      .padding(.horizontal, 22).padding(.vertical, 9)
      .piliGlass(in: Capsule(), tint: tint, fallback: AnyShapeStyle(Color.black.opacity(0.5)))
      .environment(\.colorScheme, .dark)
      .allowsHitTesting(false)
      .transition(.opacity.combined(with: .scale(scale: 0.92)))
  }
}

/// "18:28 / 21:05", a short bar, then the jump ("-5 s", "+15 s").
struct PlayerSeekHUD: View {
  let time: Double, duration: Double
  var delta: Double? = nil
  var body: some View {
    let fraction = duration > 0 ? min(1, max(0, time / duration)) : 0
    PlayerHUDCapsule {
      VStack(spacing: 5) {
        Text(clockText(time) + "  /  " + clockText(duration))
          .font(.system(size: 15, weight: .medium).monospacedDigit())
        ZStack(alignment: .leading) {
          Capsule().fill(.white.opacity(0.3))
          Capsule().fill(.white).frame(width: 116 * fraction)
        }.frame(width: 116, height: 3)
        if let delta {
          Text((delta >= 0 ? "+" : "-") + Int(abs(delta).rounded()).formatted() + " s")
            .font(.system(size: 14, weight: .medium).monospacedDigit())
            .contentTransition(.numericText())
        }
      }
    }
  }
}

/// Brightness or volume: the symbol and value over a ruler that slides under a fixed mark.
struct PlayerLevelHUD: View {
  let symbol: String
  let percent: Int
  var body: some View {
    PlayerHUDCapsule {
      VStack(spacing: 6) {
        HStack(spacing: 6) {
          Image(systemName: symbol).font(.system(size: 14, weight: .semibold))
          Text("\(percent)").font(.system(size: 15, weight: .semibold).monospacedDigit())
            .contentTransition(.numericText())
        }
        PlayerDial(value: Double(percent) / 100).frame(width: 104, height: 12)
      }
    }
  }
}

/// Ticks every 5 %, longer every 25 %, scrolling so the value sits under the yellow mark.
struct PlayerDial: View {
  let value: Double
  var body: some View {
    Canvas { ctx, size in
      let spacing: CGFloat = 8
      let mid = size.width / 2
      for i in 0...20 {
        let x = mid + (CGFloat(i) - CGFloat(value * 20)) * spacing
        guard x >= 0, x <= size.width else { continue }
        let fade = 1 - min(1, abs(x - mid) / mid)
        let tall: CGFloat = i % 5 == 0 ? 8 : 5
        ctx.fill(Path(roundedRect: CGRect(x: x - 0.75, y: (size.height - tall) / 2, width: 1.5, height: tall), cornerRadius: 0.75),
          with: .color(.white.opacity(0.25 + 0.55 * fade)))
      }
      ctx.fill(Path(roundedRect: CGRect(x: mid - 1.25, y: 0, width: 2.5, height: size.height), cornerRadius: 1.25),
        with: .color(.yellow))
    }
  }
}

/// Long-press speed: "3.00x" in a rosy capsule.
struct PlayerRateHUD: View {
  let rate: Float
  var body: some View {
    PlayerHUDCapsule(tint: Color.pink.opacity(0.35)) {
      Text(Double(rate).formatted(.number.precision(.fractionLength(2))) + "x")
        .font(.system(size: 15, weight: .semibold).monospacedDigit())
    }
  }
}

// MARK: - Panels

/// One entry of the 选集 strip.
struct PlayerEpisodeCard: Identifiable {
  let id: String
  let cover: URL?
  /// "第 199 集", "P3".
  let heading: String
  let title: String
  let current: Bool
  let select: @MainActor () async throws -> Void
}

/// 选集: a row of cover cards running under the bar, the one playing framed in white.
struct PlayerEpisodeStrip: View {
  let cards: [PlayerEpisodeCard]
  @Environment(\.playerPanelDismiss) private var dismiss
  @State private var busy: String?
  @State private var issue: String?
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let issue {
        Text(issue).font(.system(size: 13)).foregroundStyle(.white.opacity(0.8))
      }
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          LazyHStack(alignment: .top, spacing: 16) {
            ForEach(cards) { card in
              Button { pick(card) } label: { cover(card) }
                .buttonStyle(PlayerPressStyle()).id(card.id)
                .accessibilityLabel(card.heading + " " + card.title)
                .accessibilityAddTraits(card.current ? .isSelected : [])
            }
          }
          .scrollTargetLayout()
        }
        .scrollClipDisabled()
        // A lazy row has no height of its own; left open it took the whole page and lifted the
        // bar to the top.
        .frame(height: 128)
        .onAppear {
          if let now = cards.first(where: \.current) { proxy.scrollTo(now.id, anchor: .center) }
        }
      }
    }
  }
  private func cover(_ card: PlayerEpisodeCard) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Rectangle().fill(.white.opacity(0.12))
        .overlay {
          SiteThumbnail(url: card.cover) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
        }
        .overlay {
          if busy == card.id { ProgressView().tint(.white) }
        }
        .frame(width: 140, height: 79)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
          if card.current {
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white, lineWidth: 2)
          }
        }
      Text(card.heading).font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
      Text(card.title).font(.system(size: 15, weight: card.current ? .semibold : .regular))
        .foregroundStyle(.white).lineLimit(1)
    }
    .frame(width: 140, alignment: .leading)
    .contentShape(Rectangle())
  }
  private func pick(_ card: PlayerEpisodeCard) {
    guard !card.current, busy == nil else { return }
    TouchFeedback.light()
    busy = card.id
    issue = nil
    Task { @MainActor in
      defer { busy = nil }
      do {
        try await card.select()
        dismiss?()
      } catch {
        if !Task.isCancelled { issue = error.localizedDescription }
      }
    }
  }
}

/// 4K: the offered qualities as glass cards, the current one ticked.
struct PlayerQualityPanel: View {
  @ObservedObject var model: PlayerModel
  @Environment(\.playerPanelDismiss) private var dismiss
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 10) {
        Text("当前画质:").font(.system(size: 15, weight: .medium))
        Text(PlayerStreamInfo.shortName(model.quality))
          .font(.system(size: 15, weight: .semibold))
          .padding(.horizontal, 18).frame(height: 32)
          .piliGlass(in: Capsule(), fallback: AnyShapeStyle(Color.white.opacity(0.15)))
        if model.switching { ProgressView().tint(.white).controlSize(.small) }
        if let issue = model.qualityError {
          Text(issue).font(.system(size: 13)).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
        }
      }
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: 12) {
          ForEach(model.availableQualities, id: \.self) { q in card(q) }
        }
      }
      .scrollClipDisabled()
    }
    .foregroundStyle(.white)
    .environment(\.colorScheme, .dark)
  }
  private func card(_ q: Int) -> some View {
    let info = model.streamInfo(for: q)
    let current = q == model.quality
    return Button {
      guard !current, !model.switching else { return }
      TouchFeedback.light()
      Task { await model.changeQuality(q, manualVideo: true) }
      dismiss?()
    } label: {
      VStack(alignment: .leading, spacing: 9) {
        Text(StreamQuality.name(q)).font(.system(size: 17, weight: .bold))
        HStack(spacing: 14) {
          if let codec = info?.codecName {
            Label(codec, systemImage: "film")
          }
          if let rate = info?.rateText {
            Label(rate, systemImage: "rhombus")
          }
        }
        .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).labelStyle(PlayerSmallLabel())
        HStack {
          Label(info?.frameText ?? " ", systemImage: "aspectratio")
            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.75)).labelStyle(PlayerSmallLabel())
            .opacity(info?.frameText == nil ? 0 : 1)
          Spacer(minLength: 8)
          Image(systemName: current ? "checkmark.circle.fill" : "circle")
            .font(.system(size: 17))
            .foregroundStyle(current ? Color.green : Color.white.opacity(0.45))
        }
      }
      .lineLimit(1)
      .padding(14)
      .frame(width: 216, alignment: .leading)
      .piliGlass(in: RoundedRectangle(cornerRadius: 20, style: .continuous),
        fallback: AnyShapeStyle(Color.white.opacity(0.12)))
      .overlay {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
          .strokeBorder(.white.opacity(current ? 0.55 : 0.15), lineWidth: 1)
      }
      .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
    .buttonStyle(PlayerPressStyle())
    .accessibilityLabel(StreamQuality.name(q))
    .accessibilityAddTraits(current ? .isSelected : [])
  }
}

private struct PlayerSmallLabel: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) {
      configuration.icon.font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
      configuration.title
    }
  }
}
