import AVKit
import SwiftUI

struct SystemTheater: UIViewControllerRepresentable {
  @AppStorage(SpeedPresets.key) private var speedData = Data()
  @AppStorage(PresentationMode.modeKey) private var syncMode = PresentationMode.system.rawValue
  @AppStorage(PresentationMode.smoothingKey) private var syncSmoothing = "0"
  let player: AVPlayer
  let overlay: AnyView?
  var live = false
  var showsControls = true
  var onPresentation: ((Bool) -> Void)? = nil
  var pictureGravity: String? = nil
  var pipError: ((String) -> Void)? = nil
  @AppStorage("play.gravity") var gravity = "fit"
  @AppStorage("play.autoPiP") private var autoPiP = false
  @AppStorage(VideoTransport.backgroundKey) private var backgroundPlay = false
  func makeCoordinator() -> Coordinator { Coordinator() }
  @MainActor final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
    private var timing: PresentationSession?
    func configureTiming(_ vc: AVPlayerViewController, player: AVPlayer, mode: PresentationMode, smoothing: Int) {
      guard mode != .system, let container = vc.contentOverlayView else { closeTiming(); return }
      let session: PresentationSession
      if let timing { session = timing } else {
        session = PresentationSession()
        timing = session
        let surface = session.surface
        surface.frame = container.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.insertSubview(surface, at: 0)
      }
      if session.surface.gravity != vc.videoGravity { session.surface.gravity = vc.videoGravity }
      session.bind(player, mode: mode, smoothing: smoothing)
    }
    func closeTiming() { timing?.close(); timing = nil }
    var host: UIHostingController<AnyView>?
    func configureOverlay(_ content: AnyView?, in vc: AVPlayerViewController) {
      guard let content, let container = vc.contentOverlayView else {
        if let host {
          host.willMove(toParent: nil); host.view.removeFromSuperview(); host.removeFromParent()
          self.host = nil
        }
        return
      }
      if let host { host.rootView = content; return }
      let host = UIHostingController(rootView: content)
      host.view.backgroundColor = .clear
      host.view.isUserInteractionEnabled = false
      vc.addChild(host)
      host.view.frame = container.bounds
      host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      container.addSubview(host.view)
      host.didMove(toParent: vc)
      self.host = host
    }
    var presentation: ((Bool) -> Void)?
    var failure: ((String) -> Void)?
    /// Picture in picture started from the app's own button, on the player view controller's
    /// layer, so the app never has to show AVKit's controls (and their big play button).
    weak var controller: AVPlayerViewController?
    var manualPiP: AVPictureInPictureController?
    @objc func pictureInPictureRequested(_ note: Notification) {
      guard let vc = controller, let requested = note.object as AnyObject?, requested === vc.player else { return }
      if manualPiP == nil, let layer = Self.playerLayer(in: vc.view.layer) {
        let c = AVPictureInPictureController(contentSource: .init(playerLayer: layer))
        c.delegate = self
        manualPiP = c
      }
      guard let c = manualPiP else { failure?("当前无法使用画中画"); return }
      if c.isPictureInPictureActive { c.stopPictureInPicture(); return }
      Task { @MainActor [weak self] in
        for _ in 0..<30 where !c.isPictureInPicturePossible {
          try? await Task.sleep(for: .milliseconds(50))
        }
        if c.isPictureInPicturePossible { c.startPictureInPicture() } else { self?.failure?("当前无法使用画中画") }
      }
    }
    static func playerLayer(in layer: CALayer) -> AVPlayerLayer? {
      if let p = layer as? AVPlayerLayer { return p }
      for s in layer.sublayers ?? [] { if let p = playerLayer(in: s) { return p } }
      return nil
    }
    var pipState = SystemPiPLifecycle()
    weak var openingPlayer: AVPlayer?
    weak var pipScene: UIWindowScene?
    func abandon() {
      if let openingPlayer {
        PresentationSession.pictureInPicture(openingPlayer, false)
        VideoTransport.pip(openingPlayer, false)
      }
      openingPlayer = nil
      pipScene = nil
      pipState = .init()
    }
    func playerViewController(
      _ playerViewController: AVPlayerViewController,
      willBeginFullScreenPresentationWithAnimationCoordinator coordinator:
        UIViewControllerTransitionCoordinator
    ) {
      presentation?(true)
      coordinator.animate(alongsideTransition: nil) { [weak self] c in
        if c.isCancelled { self?.presentation?(false) }
      }
    }
    func playerViewController(
      _ playerViewController: AVPlayerViewController,
      willEndFullScreenPresentationWithAnimationCoordinator coordinator:
        UIViewControllerTransitionCoordinator
    ) {
      coordinator.animate(alongsideTransition: nil) { [weak self] c in
        self?.presentation?(c.isCancelled)
      }
    }
    func playerViewControllerWillStartPictureInPicture(
      _ playerViewController: AVPlayerViewController
    ) {
      openingPlayer = playerViewController.player
      pipScene = playerViewController.viewIfLoaded?.window?.windowScene
      pipState.begin()
      PresentationSession.pictureInPicture(openingPlayer, true)
      VideoTransport.pip(openingPlayer, true)
      presentation?(false)
    }
    func playerViewController(
      _ vc: AVPlayerViewController,
      restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
      let canRestore = openingPlayer != nil && vc.player === openingPlayer && vc.viewIfLoaded?.window != nil
      if canRestore { pipState.restore() }
      completionHandler(canRestore)
    }
    func playerViewControllerDidStopPictureInPicture(_ vc: AVPlayerViewController) {
      let player = openingPlayer
      PresentationSession.pictureInPicture(player, false)
      VideoTransport.pip(player, false)
      if let player, pipState.end(samePlayer: vc.player === player,
          background: pipScene?.activationState == .background,
          continuePlaying: VideoTransport.continuesInBackground(player)) {
        VideoScenePause.shared.userIntent(player)
        player.pause()
      }
      openingPlayer = nil
      pipScene = nil
    }
    func playerViewController(
      _ vc: AVPlayerViewController, failedToStartPictureInPictureWithError error: Error
    ) {
      let foreground = (vc.viewIfLoaded?.window?.windowScene ?? pipScene)?.activationState == .foregroundActive
      abandon()
      if foreground { failure?("画中画启动失败：" + error.localizedDescription) }
    }
  }
  func makeUIViewController(context: Context) -> AVPlayerViewController {
    let vc = AVPlayerViewController()
    vc.showsPlaybackControls = showsControls
    context.coordinator.controller = vc
    NotificationCenter.default.addObserver(
      context.coordinator, selector: #selector(Coordinator.pictureInPictureRequested(_:)),
      name: .piliStartPictureInPicture, object: nil)
    vc.updatesNowPlayingInfoCenter = false
    context.coordinator.presentation = onPresentation
    context.coordinator.failure = pipError
    vc.delegate = context.coordinator
    vc.videoGravity = PlaybackOption.gravity(pictureGravity ?? gravity)
    if !live {
      vc.speeds = SpeedPresets.decode(speedData).map {
        AVPlaybackSpeed(rate: Float($0), localizedName: $0.formatted() + "×")
      }
    }
    _ = backgroundPlay
    VideoTransport.background(player)
    vc.player = player
    vc.allowsPictureInPicturePlayback = true
    vc.canStartPictureInPictureAutomaticallyFromInline = autoPiP
    configurePresentation(vc, coordinator: context.coordinator)
    return vc
  }
  func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
    _ = backgroundPlay
    VideoTransport.background(player)
    context.coordinator.presentation = onPresentation
    context.coordinator.failure = pipError
    if vc.showsPlaybackControls != showsControls { vc.showsPlaybackControls = showsControls }
    if vc.player !== player { context.coordinator.abandon(); vc.player = player }
    let targetGravity = PlaybackOption.gravity(pictureGravity ?? gravity)
    if vc.videoGravity != targetGravity { vc.videoGravity = targetGravity }
    if vc.canStartPictureInPictureAutomaticallyFromInline != autoPiP {
      vc.canStartPictureInPictureAutomaticallyFromInline = autoPiP
    }
    let speeds = SpeedPresets.decode(speedData)
    if !live && vc.speeds.map(\.rate) != speeds.map(Float.init) {
      vc.speeds = speeds.map {
        AVPlaybackSpeed(rate: Float($0), localizedName: $0.formatted() + "×")
      }
    }
    configurePresentation(vc, coordinator: context.coordinator)
  }
  private func configurePresentation(_ vc: AVPlayerViewController, coordinator: Coordinator) {
    coordinator.configureTiming(vc, player: player, mode: PresentationMode(rawValue: syncMode) ?? .system,
      smoothing: PresentationMode.validSmoothing(syncSmoothing) ?? 0)
    coordinator.configureOverlay(overlay, in: vc)
  }
  static func dismantleUIViewController(_ vc: AVPlayerViewController, coordinator: Coordinator) {
    coordinator.abandon(); coordinator.closeTiming(); coordinator.configureOverlay(nil, in: vc)
  }
}
struct TheaterSheet: View {
  @StateObject private var bulletInspector = BulletInspector()
  @AppStorage("dm.tap") private var tapBullet = true
  @State private var drawer = false
  var subject: TheaterSubject? = nil
  var playlist: AnyView? = nil
  /// 选集 as cover cards under the bar; without them 选集 opens the side panel's list.
  var episodes: [PlayerEpisodeCard] = []
  var continueBadge:AnyView?=nil
  /// Shown in the header, like the original client's fullscreen title.
  var title: String? = nil
  @State private var showTimeline = false
  @State private var chromeVisible = true
  @State private var locked = false
  @AppStorage("theater.orientation") private var orientationPref: Int?
  /// Read once on entry: folding or unfolding a Duo mid-fullscreen must not rotate it back.
  @State private var entryMode = TheaterOrientation.defaultMode
  private var orientation: Int { orientationPref ?? entryMode }
  @AppStorage("theater.lockButton") private var allowLock = true
  @AppStorage("theater.captureButton") private var allowCapture = true
  @ObservedObject var model: PlayerModel
  @AppStorage("play.subtitleSize") var subtitleSize = 16.0
  var keyStep: ((Bool) -> Void)? = nil
  var entry: InlinePlayerFrame.Snapshot?
  let closing: Bool
  var closeWhenUpright = false
  let covered: (Bool) -> Void
  let close: () -> Void
  private var showBullets: Bool {
    get { model.preferences.bullets }
    nonmutating set { model.preferences.bullets = newValue }
  }
  var engagement: EngagementItem? = nil
  @AppStorage("theater.actionBar") private var actionsEnabled = true
  @State private var showEngagement = false
  @State private var bulletSettings = false
  /// The format chip shows for a few seconds whenever a stream starts.
  @State private var infoShown = false
  @State private var infoPulse = 0
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    FullscreenStage(mode: FullscreenMode(rawValue: orientation) ?? .video,
      picture: model.engine.playbackSize, entry: entry, closing: closing,
      inline: { InlinePlayerFrame.current(model.engine) }, covered: covered, finish: { dismiss() }) {
      TheaterWorkspace(open: drawer && !locked) { playback } panel: {
        TheaterTools(model: model, subject: subject, playlist: playlist, close: { drawer = false },
          bulletSnapshot: { bulletInspector.snapshot?() ?? [] },
          engagement: actionsEnabled ? engagement : nil).id(subject?.type)
      }
    }
    .ignoresSafeArea()
    .presentationBackground(.clear)
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    .interactiveDismissDisabled()
    .onAppear {
      UIDevice.current.beginGeneratingDeviceOrientationNotifications()
      if closeWhenUpright && UIDevice.current.orientation == .portrait { close() }
    }
    .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
      if closeWhenUpright && UIDevice.current.orientation == .portrait { close() }
    }
    .onDisappear { UIDevice.current.endGeneratingDeviceOrientationNotifications() }
  }
  private func showInfo() {
    withAnimation(.easeOut(duration: 0.25)) { infoShown = true }
    infoPulse &+= 1
  }
  private func toggleLock() {
    TouchFeedback.light()
    locked.toggle()
    if locked {
      bulletInspector.pick = nil
      drawer = false
      showEngagement = false
    }
  }
  /// The fullscreen chrome's contents (laid out by Theater's fullscreen controls): ✕ and the
  /// title, a row of white icons, then play / next and the 4K · 选集 · 倍速 words.
  private var slots: PlayerChromeSlots {
    var s = PlayerChromeSlots(title: title)
    s.close = { close() }
    s.tools = AnyView(tools)
    s.info = infoShown ? model.streamInfo.map { AnyView(PlayerFormatChip(info: $0)) } : nil
    s.next = keyStep.map { step in { TouchFeedback.light(); step(true) } }
    if !model.availableQualities.isEmpty {
      s.panels.append(PlayerPanelSlot(
        id: "quality", title: model.switching ? "切换中" : PlayerStreamInfo.shortName(model.quality),
        content: AnyView(PlayerQualityPanel(model: model))))
    }
    if episodes.count > 1 {
      s.panels.append(PlayerPanelSlot(id: "episodes", title: "选集", content: AnyView(PlayerEpisodeStrip(cards: episodes))))
    }
    s.menus = AnyView(
      HStack(spacing: 18) {
        // Lists without covers (the library queue) keep the side panel.
        if episodes.count <= 1, playlist != nil {
          Button {
            withAnimation(.snappy(duration: 0.3)) { drawer = true }
          } label: { PlayerWordGlyph(text: "选集") }
        }
        PlayerSpeedMenu(model: model, word: true)
      })
    s.lock = allowLock ? { toggleLock() } : nil
    return s
  }
  /// The header icons: cast, bullets, send a bullet, picture in picture, capture, picture fit,
  /// subtitles, more. A portrait (vertical video) screen has room for the essentials only; the
  /// rest stay in 更多.
  private var tools: some View {
    ViewThatFits(in: .horizontal) {
      toolRow(full: true)
      toolRow(full: false)
    }
  }
  @ViewBuilder private func toolRow(full: Bool) -> some View {
    // 44 pt cells 50 pt apart, as in the reference header.
    HStack(spacing: full ? 6 : 2) {
      if full { PlayerRoutePicker().accessibilityLabel("隔空播放") }
      Button {
        TouchFeedback.light()
        showBullets.toggle()
      } label: {
        PlayerBulletGlyph(on: showBullets)
      }
      .accessibilityLabel(showBullets ? "关闭弹幕" : "开启弹幕")
      .contextMenu {
        Button("弹幕设置", systemImage: "text.bubble.badge.gearshape") { bulletSettings = true }
      }
      if let cid = subject?.cid, let bvid = subject?.bvid {
        EpisodeBulletAction(cid: cid, bvid: bvid, model: model, glyph: true)
      }
      PlayerPiPButton(player: model.engine, tool: true)
      if full {
        if allowCapture { CaptureButton(player: model.engine, tool: true) }
        PlayerFitMenu(player: model.engine, session: PictureSession.shared(model.engine), tool: true)
        PlayerCaptionMenu(session: model.captions, tool: true)
      }
      Button {
        withAnimation(.snappy(duration: 0.3)) { drawer.toggle() }
      } label: {
        PlayerToolGlyph(symbol: "ellipsis.circle")
      }
      .accessibilityLabel(drawer ? "关闭播放面板" : "更多")
      .contextMenu {
        Button(showTimeline ? "隐藏时间轴" : "显示时间轴", systemImage: "timeline.selection") {
          withAnimation(.snappy(duration: 0.3)) { showTimeline.toggle() }
        }
        Button("弹幕设置", systemImage: "text.bubble.badge.gearshape") { bulletSettings = true }
      }
    }
  }
  private var playback: some View {
    ZStack(alignment: .topTrailing) {
      Theater(
        player: model.engine,
        overlay: AnyView(
          ZStack(alignment: .bottom) {
            if showBullets {
              BulletOverlay(
                items: model.bullets, time: model.seconds, revision: model.revision,
                clock: model.engine, inspector: bulletInspector,
                fullscreen: true)
            }
          }), showsControls: !locked,
        interaction: AnyView(
          ZStack {
            if model.ready && !locked {
              PlayerGestures(
                model: model, inspector: showBullets && tapBullet ? bulletInspector : nil,
                enterTheater: { close() }, fullscreen: true)
              if showBullets && tapBullet {
                PinnedBullet(
                  inspector: bulletInspector, cid: model.timeline.source?.cid,
                  duration: model.duration, seek: model.seek)
              }
            }
          }), caption: AnyView(PlaybackCaption(model: model, fullscreen: true, interactive: !locked)),
        marks: AnyView(ViewportMarks(model: model)),timeline:model.timeline, fullscreen: true, toggle: model.toggle,
        seek: model.seek, expand: { close() }, upscale: model.upscale
      ).environment(\.styledSubtitles,model.captions)
      .environment(\.playerChrome, slots)
      .onPreferenceChange(PlayerControlsVisibleKey.self) { chromeVisible = $0 }
      .modifier(PlaybackEdgeInsets(fullscreen: true))
      if !locked{VStack{Spacer();HStack{EpisodeClipPrompt(model:model);Spacer()}.padding(.leading,10)}.padding(.bottom,66)}
      if !locked,let continueBadge{VStack{Spacer();HStack{continueBadge;Spacer()}.padding(.leading,10)}.padding(.bottom,66)}
      if model.storyEnded { StoryFinish(model: model).onAppear { locked = false } }
      if locked {
        Color.clear.contentShape(Rectangle()).ignoresSafeArea().accessibilityHidden(true)
      }
      if locked {
        // Controls are hidden while locked; the closed lock sits where it was offered.
        GeometryReader { frame in
          VStack {
            Spacer(minLength: 0)
            HStack {
              Button { toggleLock() } label: {
                Image(systemName: "lock").font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                  .frame(width: 44, height: 48, alignment: .leading).contentShape(Rectangle())
                  .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
              }
              .buttonStyle(PlayerPressStyle()).accessibilityLabel("解锁播放控件")
              Spacer(minLength: 0)
            }
          }
          .padding(.horizontal, frame.size.width < frame.size.height ? 16 : 0)
        }
        .transition(.opacity)
      }
    }
    .animation(.smooth(duration: 0.25), value: locked)
    .onAppear { if model.streamInfo != nil { showInfo() } }
    .onChange(of: model.streamInfo) { _, info in if info != nil { showInfo() } }
    .task(id: infoPulse) {
      guard infoShown else { return }
      do { try await Task.sleep(for: .seconds(5)) } catch { return }
      withAnimation(.easeOut(duration: 0.25)) { infoShown = false }
    }
    .piliSheet(isPresented: $bulletSettings) {
      PiliNavigationStack {
        DanmakuStylePanel().toolbar { Button("完成") { bulletSettings = false } }
      }
      .presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    .statusBarHidden(true)
    .persistentSystemOverlays(.hidden)
    .safeAreaInset(edge: .bottom) {
      if !locked && showTimeline {
        TimelineSlider(model: model).padding(8).foregroundStyle(.white).background(
          .black.opacity(0.85))
      }
    }.background { Color.black.ignoresSafeArea() }
      .modifier(
        PlayerKeyboard(
          player: model.engine, locked: locked, toggle: model.toggle,
          fullscreen: {
            locked = false
            close()
          }, bullets: { showBullets.toggle() },
          lock: { toggleLock() }, step:keyStep,allowCapture:true,full:true,foreground:!drawer,model:model,item:engagement,cid:subject?.cid,creator:engagement?.episode==nil && subject?.shortcutCanFollow==true ? subject?.creator:nil,bvid:subject?.bvid)
      )
      .interactiveDismissDisabled(locked)
  }
}

extension Notification.Name {
  /// Posted with the `AVPlayer` whose inline player should enter picture in picture.
  static let piliStartPictureInPicture = Notification.Name("PiliNative.startPictureInPicture")
}
/// The app-started picture in picture shares the player view controller's lifecycle handling.
extension SystemTheater.Coordinator: @preconcurrency AVPictureInPictureControllerDelegate {
  func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
    if let vc = controller { playerViewControllerWillStartPictureInPicture(vc) }
  }
  func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
    if let vc = controller { playerViewControllerDidStopPictureInPicture(vc) }
  }
  func pictureInPictureController(
    _ c: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    if let vc = controller {
      playerViewController(vc, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: completionHandler)
    } else { completionHandler(false) }
  }
  func pictureInPictureController(
    _ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error
  ) {
    if let vc = controller { playerViewController(vc, failedToStartPictureInPictureWithError: error) }
  }
}
