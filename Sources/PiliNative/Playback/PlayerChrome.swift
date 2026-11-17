import AVKit
import SwiftUI

/// Buttons a page places into the player's bars, following the original client's layout:
/// header = back/title on the left, tools on the right; bottom = play/time on the left,
/// menus and fullscreen on the right; fullscreen adds an action row under the header and
/// lock / screenshot buttons at the vertical centre of each edge.
struct PlayerChromeSlots {
  var title: String? = nil
  var subtitle: String? = nil
  var headerLeading: AnyView? = nil
  var headerTrailing: AnyView? = nil
  var bottomTrailing: AnyView? = nil
  /// After play/time on the left: previous / next part, as in the original.
  var bottomLeading: AnyView? = nil
  /// First on the right before the picture-fit menu: the episode list button.
  var bottomEpisode: AnyView? = nil
  /// Shown only when the player is wide (>= 500 pt) or fullscreen, like the original's quality.
  var bottomWide: AnyView? = nil
  var underHeader: AnyView? = nil
  var edgeLeading: AnyView? = nil
  var edgeTrailing: AnyView? = nil
}
private struct PlayerChromeKey: EnvironmentKey { static let defaultValue = PlayerChromeSlots() }
extension EnvironmentValues {
  var playerChrome: PlayerChromeSlots {
    get { self[PlayerChromeKey.self] }
    set { self[PlayerChromeKey.self] = newValue }
  }
}

/// Whether the player's own controls are on screen; hosts use it to fade their extras in step.
struct PlayerControlsVisibleKey: PreferenceKey {
  static let defaultValue = true
  static func reduce(value: inout Bool, nextValue: () -> Bool) { value = nextValue() }
}

/// White SF Symbol control in the original client's 40 pt cell; a soft shadow keeps it legible
/// on bright frames.
struct PlayerGlyph: View {
  let symbol: String
  var size: CGFloat = 19
  var dimmed = false
  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size, weight: .medium))
      .foregroundStyle(.white.opacity(dimmed ? 0.55 : 1))
      .frame(width: 40, height: 40)
      .contentShape(Rectangle())
      .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
      .contentTransition(.symbolEffect(.replace))
  }
}

/// Text control for menus such as speed, quality and picture fit (13 pt, like the original).
struct PlayerTextGlyph: View {
  let text: String
  var body: some View {
    Text(text)
      .font(.system(size: 13, weight: .semibold)).monospacedDigit()
      .foregroundStyle(.white)
      .lineLimit(1)
      .padding(.horizontal, 8).frame(minWidth: 40, minHeight: 40)
      .contentShape(Rectangle())
      .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
      .contentTransition(.numericText())
  }
}

/// Native press feedback: a quick dip in scale and opacity, springing back.
struct PlayerPressStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .scaleEffect(configuration.isPressed ? 0.86 : 1)
      .opacity(configuration.isPressed ? 0.6 : 1)
      .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
  }
}

/// Glass tile for the fullscreen edge buttons (lock / screenshot).
struct PlayerEdgeButton: View {
  let symbol: String, label: String
  let action: () -> Void
  var body: some View {
    Button(action: action) {
      Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
        .frame(width: 44, height: 44)
        .contentTransition(.symbolEffect(.replace))
    }
    .buttonStyle(PlayerPressStyle())
    .piliGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true,
      fallback: AnyShapeStyle(Color.black.opacity(0.3)))
    .accessibilityLabel(label)
  }
}

// MARK: - Bottom-right menus (native menus in place of the original popups)

struct PlayerSpeedMenu: View {
  @ObservedObject var model: PlayerModel
  @AppStorage(SpeedPresets.key) private var data = Data()
  @State private var current = 1.0
  var body: some View {
    Menu {
      Picker("倍速", selection: Binding(get: { current }, set: { v in
        current = v
        model.rate = Float(v)
        TouchFeedback.light()
      })) {
        ForEach(SpeedPresets.decode(data).reversed(), id: \.self) { s in
          Text(s.formatted() + "×").tag(s)
        }
      }
    } label: {
      // Always the rate, like the original ("1.0X").
      PlayerTextGlyph(text: current.formatted(.number.precision(.fractionLength(1...2))) + "X")
    }
    .menuOrder(.fixed)
    .accessibilityLabel("倍速").accessibilityValue(current.formatted() + "倍")
    .onAppear { current = Double(model.rate) }
    .onReceive(model.engine.statePublisher) { _ in current = Double(model.rate) }
  }
}

struct PlayerQualityMenu: View {
  @ObservedObject var model: PlayerModel
  private func short(_ q: Int) -> String {
    StreamQuality.name(q).split(separator: " ").first.map(String.init) ?? StreamQuality.name(q)
  }
  var body: some View {
    if model.availableQualities.count > 1 {
      Menu {
        Picker("画质", selection: Binding(get: { model.quality }, set: { q in
          guard q != model.quality else { return }
          Task { await model.changeQuality(q, manualVideo: true) }
        })) {
          ForEach(model.availableQualities, id: \.self) { q in Text(StreamQuality.name(q)).tag(q) }
        }
      } label: {
        PlayerTextGlyph(text: model.switching ? "切换中" : short(model.quality))
      }
      .menuOrder(.fixed)
      .accessibilityLabel("画质").accessibilityValue(StreamQuality.name(model.quality))
    }
  }
}

struct PlayerCaptionMenu: View {
  @ObservedObject var session: SubtitleSession
  var body: some View {
    if !session.tracks.isEmpty {
      Menu {
        Picker("字幕", selection: Binding(
          get: { session.first },
          set: { v in Task { await session.select(v, secondary: false) } })
        ) {
          Text("关闭字幕").tag(nil as String?)
          ForEach(session.tracks) { r in Text(r.name).tag(Optional(r.id)) }
        }
      } label: {
        PlayerGlyph(symbol: session.first == nil ? "captions.bubble" : "captions.bubble.fill")
      }
      .accessibilityLabel("字幕")
    }
  }
}

struct PlayerFitMenu: View {
  let player: any PlaybackEngine
  @ObservedObject var session: PictureSession
  @AppStorage("play.gravity") private var stored = PictureFit.fit.rawValue
  var body: some View {
    Menu {
      Picker("画面比例", selection: Binding(get: { stored }, set: { value in
        session.changedItem = player.playbackItem.map(ObjectIdentifier.init)
        stored = value
      })) {
        ForEach(PictureFit.allCases, id: \.self) { Text($0.title).tag($0.rawValue) }
      }
      Toggle("水平镜像", isOn: $session.mirrorX.withTouchFeedback)
      Toggle("垂直镜像", isOn: $session.mirrorY.withTouchFeedback)
    } label: {
      PlayerTextGlyph(text: (PictureFit(rawValue: stored) ?? .fit).title)
    }
    .accessibilityLabel("画面比例与镜像")
  }
}

// MARK: - Original header buttons

/// Picture in picture from the header, as in the original.
struct PlayerPiPButton: View {
  let player: any PlaybackEngine
  var body: some View {
    Button {
      TouchFeedback.light()
      NotificationCenter.default.post(name: .piliStartPictureInPicture, object: player)
    } label: {
      PlayerGlyph(symbol: "pip.enter")
    }
    .accessibilityLabel("画中画")
  }
}

/// "返回主页": closes every page back to the home tab.
struct PlayerHomeButton: View {
  var body: some View {
    Button {
      TouchFeedback.light()
      NotificationCenter.default.post(name: AppLinkPage.returnHome, object: nil)
    } label: {
      PlayerGlyph(symbol: "house", size: 16)
    }
    .accessibilityLabel("返回主页")
  }
}

/// DLNA projection, matching the original onCast action.
struct PlayerCastButton: View {
  let player: any PlaybackEngine
  let subject: CastSubject
  @State private var sheet = false
  var body: some View {
    Button { sheet = true } label: { PlayerGlyph(symbol: "airplayvideo") }
      .disabled(!subject.valid).accessibilityLabel("投屏")
      .piliSheet(isPresented: $sheet) {
        PiliNavigationStack { CastView(subject: subject, player: player) }
      }
  }
}

/// The original's centred indicator pill (volume, brightness): icon and percentage.
struct PlayerLevelPill: View {
  let symbol: String
  let percent: Int
  var body: some View {
    HStack(spacing: 3) {
      Image(systemName: symbol).font(.system(size: 16, weight: .medium))
      Text("\(percent)%").font(.system(size: 13).monospacedDigit())
    }
    .foregroundStyle(.white)
    .padding(.horizontal, 9).padding(.vertical, 6)
    .background(Color.black.opacity(0.53), in: Capsule())
    .allowsHitTesting(false)
  }
  static func volumeSymbol(_ level: Double) -> String {
    level <= 0.001 ? "speaker.slash.fill" : level < 0.5 ? "speaker.wave.1.fill" : "speaker.wave.3.fill"
  }
  static func brightnessSymbol(_ level: Double) -> String {
    level < 1.0 / 3 ? "sun.min.fill" : level < 2.0 / 3 ? "sun.max" : "sun.max.fill"
  }
}

/// The original's top toast (long-press speed, drag-seek time): text on a dark pill.
struct PlayerTopToast: View {
  let text: String
  var rounded: CGFloat = 16
  var body: some View {
    Text(text).font(.system(size: 13).monospacedDigit()).foregroundStyle(.white)
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(Color.black.opacity(0.53), in: RoundedRectangle(cornerRadius: rounded, style: .continuous))
      .allowsHitTesting(false)
  }
}

/// Shown while playback waits on the network mid-play, like the original's buffering mark.
struct PlayerBufferingIndicator: View {
  let player: any PlaybackEngine
  @State private var waiting = false
  @State private var shown = false
  var body: some View {
    ZStack {
      if shown {
        VStack(spacing: 6) {
          ProgressView().tint(.white)
          Text("加载中...").font(.system(size: 12)).foregroundStyle(.white)
        }
        .padding(18)
        .background(
          RadialGradient(colors: [.black.opacity(0.26), .clear], center: .center, startRadius: 0, endRadius: 60))
        .transition(.opacity)
      }
    }
    .allowsHitTesting(false)
    .animation(.easeInOut(duration: 0.15), value: shown)
    .onReceive(player.statePublisher) { _ in
      waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
    }
    .task(id: waiting) {
      if !waiting {
        shown = false
        return
      }
      // Short hitches stay invisible.
      try? await Task.sleep(for: .milliseconds(450))
      if !Task.isCancelled && waiting { shown = true }
    }
  }
}

/// "选集": opens the episode list as a panel under the player (the original's sheet), or as the
/// page's own list when no panel host is on screen.
struct PlayerEpisodeButton: View {
  let list: AnyView
  let fallback: () -> Void
  @Environment(\.replyPanelPresenter) private var presenter
  var body: some View {
    Button {
      TouchFeedback.light()
      if presenter?.push("选集", list) != true { fallback() }
    } label: {
      PlayerGlyph(symbol: "list.bullet")
    }
    .accessibilityLabel("选集")
  }
}

/// Previous / next part, after the time on the left.
struct PlayerStepButtons: View {
  let step: (Bool) -> Void
  var body: some View {
    HStack(spacing: 0) {
      Button { TouchFeedback.light(); step(false) } label: { PlayerGlyph(symbol: "backward.end.fill", size: 17) }
        .accessibilityLabel("上一集")
      Button { TouchFeedback.light(); step(true) } label: { PlayerGlyph(symbol: "forward.end.fill", size: 17) }
        .accessibilityLabel("下一集")
    }
  }
}

/// A bare picture of the player, used while fullscreen grows out of / shrinks into the page.
struct PlayerPictureLayer: View {
  let player: any PlaybackEngine
  var body: some View {
    if let native = player.nativePlayer { AVPlayerPictureLayer(player: native) }
    else if let mpv = player as? MPVPlayer { MPVVideoView(player: mpv) }
  }
}
private struct AVPlayerPictureLayer: UIViewRepresentable {
  let player: AVPlayer
  final class LayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
  }
  func makeUIView(context: Context) -> LayerView {
    let v = LayerView()
    v.backgroundColor = .clear
    v.isUserInteractionEnabled = false
    v.playerLayer.videoGravity = .resizeAspect
    v.playerLayer.player = player
    return v
  }
  func updateUIView(_ v: LayerView, context: Context) {
    if v.playerLayer.player !== player { v.playerLayer.player = player }
  }
}

/// Where the inline player sits on screen (window coordinates), per orientation, so fullscreen
/// can grow out of it and shrink back into it. Kept outside view state: it changes every scroll.
@MainActor enum InlinePlayerFrame {
  private static var frames: [ObjectIdentifier: [Bool: CGRect]] = [:]
  static func record(_ rect: CGRect, player: any PlaybackEngine) {
    guard let portrait = scenePortrait else { return }
    frames[ObjectIdentifier(player), default: [:]][portrait] = rect
  }
  static func current(_ player: any PlaybackEngine) -> CGRect? {
    guard let portrait = scenePortrait else { return nil }
    return frames[ObjectIdentifier(player)]?[portrait]
  }
  private static var scenePortrait: Bool? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .first { $0.activationState == .foregroundActive }
    return scene.map { $0.interfaceOrientation.isPortrait }
  }
}
extension View {
  /// Records this view's frame as the inline player's, for the fullscreen transition.
  func recordsInlinePlayerFrame(_ player: any PlaybackEngine) -> some View {
    onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
      InlinePlayerFrame.record($0, player: player)
    }
  }
}
