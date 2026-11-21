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
  /// Controls fade in and out quickly, without sliding (the reference player takes about a
  /// tenth of a second either way).
  static let fade = Animation.easeOut(duration: 0.12)
  /// The bar rises and a panel slides up under it.
  static let panel = Animation.spring(response: 0.36, dampingFraction: 0.86)
  /// The original client's portrait controls (its control container animator): 200 ms in and
  /// 150 ms out on a (0.68, 0.8, 0.42, 0.99) curve, every bar fading while it slides `slide`
  /// points toward its own edge. The page's back / home use the same motion, so nothing on the
  /// picture moves out of step.
  static func inline(_ showing: Bool) -> Animation {
    .timingCurve(0.68, 0.8, 0.42, 0.99, duration: showing ? 0.2 : 0.15)
  }
  static let slide: CGFloat = 12
  /// The fading slide of a bar at the top (`edge` .top) or bottom of the picture.
  static func bar(_ edge: VerticalEdge) -> AnyTransition {
    .opacity.combined(with: .offset(y: edge == .top ? -slide : slide))
  }
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

/// The glass chip at the top after a stream starts: quality and range, codec and rate, then the
/// audio track. It plays the reference player's entrance by itself, whether or not the controls
/// are up: the glyph draws on in a glass circle, the capsule grows to the right uncovering the
/// text, holds, then folds back into the circle and the glyph draws off. Give it a new identity
/// to replay it (a new stream).
struct PlayerFormatChip: View {
  let info: PlayerStreamInfo
  /// 0 gone, 1 the glyph in its circle, 2 open.
  @State private var stage = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  var body: some View {
    HStack(spacing: 9) {
      ChipGlyph(shown: stage > 0)
        .frame(width: 24, height: 24)
      if stage == 2 {
        details
          .fixedSize()
          .transition(.asymmetric(
            insertion: .opacity.animation(.easeOut(duration: 0.22).delay(0.1)),
            removal: .opacity.animation(.easeOut(duration: 0.12))))
      }
    }
    .foregroundStyle(.white).lineLimit(1)
    .padding(.leading, 10).padding(.trailing, stage == 2 ? 18 : 10).padding(.vertical, 8)
    .background {
      Color.clear
        .piliGlass(in: Capsule(), fallback: AnyShapeStyle(Color.black.opacity(0.45)))
        .opacity(stage == 0 ? 0 : 1)
    }
    // The capsule's edge uncovers the text as it grows and covers it as it folds.
    .clipShape(Capsule())
    .environment(\.colorScheme, .dark)
    .accessibilityElement(children: .combine)
    .task {
      let open = Animation.spring(response: 0.5, dampingFraction: 0.86)
      withAnimation(.easeOut(duration: 0.2)) { stage = 1 }
      if !(await pause(0.28)) { return }
      withAnimation(reduceMotion ? .easeOut(duration: 0.2) : open) { stage = 2 }
      if !(await pause(4.6)) { return }
      withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.92)) { stage = 1 }
      if !(await pause(0.7)) { return }
      withAnimation(.easeIn(duration: 0.22)) { stage = 0 }
    }
  }
  private func pause(_ seconds: Double) async -> Bool {
    do { try await Task.sleep(for: .seconds(seconds)) } catch { return false }
    return true
  }
  private var details: some View {
    HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 1) {
        Text(info.headline).font(.system(size: 15, weight: .semibold))
        if let detail = [info.codecName, info.rateText].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
          Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.65))
        }
      }
      if let audio = info.audioName {
        VStack(alignment: .leading, spacing: 1) {
          Text(audio).font(.system(size: 14, weight: .semibold))
          if let detail = info.audioDetail {
            Text(detail).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.65))
          }
        }
      }
    }
  }
}

/// The chip's glyph: drawn on and off stroke by stroke on iOS 26 (SF Symbols' draw effect),
/// popped in and out elsewhere.
private struct ChipGlyph: View {
  let shown: Bool
  var body: some View {
    let glyph = Image(systemName: "dot.radiowaves.forward").font(.system(size: 17, weight: .bold))
    if #available(iOS 26.0, *) {
      glyph.symbolEffect(.drawOn, isActive: !shown)
    } else {
      glyph.opacity(shown ? 1 : 0).scaleEffect(shown ? 1 : 0.4)
    }
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
      .offset(y: GlyphOptics.tool(symbol))
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
  @MainActor private static let idle = NSCache<NSString, AVRoutePickerView>()
  final class Coordinator: NSObject, AVRoutePickerViewDelegate {
    private let lock = NSLock()
    private var showingRoutes = false
    var presenting: Bool { lock.withLock { showingRoutes } }
    func routePickerViewWillBeginPresentingRoutes(_ routePickerView: AVRoutePickerView) {
      lock.withLock { showingRoutes = true }
    }
    func routePickerViewDidEndPresentingRoutes(_ routePickerView: AVRoutePickerView) {
      lock.withLock { showingRoutes = false }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> AVRoutePickerView {
    // The full-screen bars are removed at the end of their fade. Reuse only a detached
    // picker, so two players or overlapping transitions keep independent system controls.
    let previous = Self.idle.object(forKey: "picker")
    Self.idle.removeObject(forKey: "picker")
    let v = previous.flatMap { $0.superview == nil && $0.window == nil ? $0 : nil } ?? AVRoutePickerView()
    v.delegate = context.coordinator
    v.tintColor = .clear
    v.activeTintColor = .clear
    v.prioritizesVideoDevices = true
    v.backgroundColor = .clear
    return v
  }
  func updateUIView(_ v: AVRoutePickerView, context: Context) {}
  static func dismantleUIView(_ v: AVRoutePickerView, coordinator: Coordinator) {
    guard !coordinator.presenting else { return }
    v.delegate = nil
    idle.setObject(v, forKey: "picker")
  }
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
  @State private var detents = SlideDetents()
  /// Where the drag began, as a fraction of the length.
  @State private var origin: Double?
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
            if scrub == nil {
              TouchFeedback.light(); editing(true)
              origin = min(1, max(0, readout.seconds / clock.duration))
            }
            let f = min(1, max(0, v.location.x / w))
            scrub = f * clock.duration
            detents.move(f, origin: origin)
          }.onEnded { v in
            if clock.duration > 0 { seek(min(1, max(0, v.location.x / w)) * clock.duration) }
            scrub = nil
            origin = nil
            detents.finish()
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

/// The reference player's feedback capsule at the top centre (seek, level, speed): clear Liquid
/// Glass — the picture shows through, bent at the rim, barely dimmed — not the frosted regular
/// glass, which over a bright frame turned into a flat grey pill. Before iOS 26, a dark blur.
struct PlayerHUDCapsule<Content: View>: View {
  @ViewBuilder let content: () -> Content
  @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
  var body: some View {
    content()
      .foregroundStyle(.white)
      .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
      .padding(.horizontal, 22).padding(.vertical, 9)
      .modifier(PlayerClearGlass(shape: Capsule(), reduceTransparency: reduceTransparency))
      .environment(\.colorScheme, .dark)
      .allowsHitTesting(false)
      .transition(.scale(scale: 0.9).combined(with: .opacity))
  }
}
/// Clear Liquid Glass over the picture, lightly dimmed for white text; a dark blur with a hairline
/// rim before iOS 26.
struct PlayerClearGlass<S: InsettableShape>: ViewModifier {
  let shape: S
  var reduceTransparency = false
  @ViewBuilder func body(content: Content) -> some View {
    if reduceTransparency {
      content.background(Color.black.opacity(0.75), in: shape)
    } else if #available(iOS 26, *) {
      content
        .background(Color.black.opacity(0.14), in: shape)
        .glassEffect(.clear, in: shape)
    } else {
      content.background {
        shape.fill(.ultraThinMaterial)
          .overlay(shape.fill(Color.black.opacity(0.22)))
          .overlay(shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.6))
      }
    }
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
  /// The reference player draws outline glyphs here: a plain sun, and a speaker whose waves
  /// fill in with the level.
  @ViewBuilder private var glyph: some View {
    if symbol.hasPrefix("sun") {
      Image(systemName: "sun.max")
    } else if percent <= 0 {
      Image(systemName: "speaker.slash")
    } else {
      Image(systemName: "speaker.wave.3", variableValue: Double(percent) / 100)
    }
  }
  var body: some View {
    PlayerHUDCapsule {
      VStack(spacing: 6) {
        HStack(spacing: 7) {
          glyph.font(.system(size: 14, weight: .medium))
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

/// Long-press speed in the reference player's style: the same smoked glass capsule as the seek
/// and level feedback, reading "快进 3×" (its speeds are written as in its speed menu: 1.75×, 2×).
struct PlayerRateHUD: View {
  let rate: Float
  var body: some View {
    PlayerHUDCapsule {
      HStack(spacing: 6) {
        Image(systemName: "forward.fill").font(.system(size: 13, weight: .semibold))
        Text("快进 " + Double(rate).formatted(.number.precision(.fractionLength(0...2))) + "×")
          .font(.system(size: 15, weight: .medium).monospacedDigit())
      }
    }
  }
}

/// Paused with the controls hidden: the play mark comes first, then a clear glass bubble forms
/// around it, as in the reference player. Tapping it plays.
struct PlayerPausedBubble: View {
  let play: () -> Void
  @State private var formed = false
  var body: some View {
    Button(action: play) {
      Image(systemName: "play.fill")
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(.white)
        // The triangle's ink sits left of its bounds' centre.
        .offset(x: 3)
        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
        .frame(width: 80, height: 80)
        .background {
          if formed {
            Color.clear
              .modifier(PlayerClearGlass(shape: Circle()))
              .transition(.scale(scale: 0.6).combined(with: .opacity))
          }
        }
        .contentShape(Circle())
    }
    .buttonStyle(PlayerPressStyle())
    .environment(\.colorScheme, .dark)
    .accessibilityLabel("播放")
    .task {
      try? await Task.sleep(for: .milliseconds(180))
      withAnimation(.spring(response: 0.38, dampingFraction: 0.78)) { formed = true }
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
