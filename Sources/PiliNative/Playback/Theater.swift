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
  var continueBadge:AnyView?=nil
  /// Shown in the header, like the original client's fullscreen title.
  var title: String? = nil
  @State private var showTimeline = false
  @State private var chromeVisible = true
  @State private var locked = false
  @AppStorage("theater.orientation") private var orientation =
    UIDevice.current.userInterfaceIdiom == .pad ? 1 : 0
  @AppStorage("theater.lockButton") private var allowLock = true
  @AppStorage("theater.captureButton") private var allowCapture = true
  @ObservedObject var model: PlayerModel
  @AppStorage("play.subtitleSize") var subtitleSize = 17.0
  var keyStep: ((Bool) -> Void)? = nil
  /// The inline player's frame (window coordinates): the picture grows out of it on entry and
  /// shrinks back into it on exit, like the original's single continuous player.
  var origin: (() -> CGRect?)? = nil
  /// Reports whether fullscreen fully covers the page (the page detaches its inline player
  /// only then, and reattaches it as soon as leaving begins).
  var covered: ((Bool) -> Void)? = nil
  /// Bumped by the page to close from outside (turning upright, end of video).
  var closeRequest = 0
  @State private var closing = false
  private enum Stage { case growing, shown, shrinking }
  @State private var stage: Stage = .growing
  @State private var expanded = false
  @State private var bridge = false
  @State private var frameFrom: CGRect?
  private var showBullets: Bool {
    get { model.preferences.bullets }
    nonmutating set { model.preferences.bullets = newValue }
  }
  var engagement: EngagementItem? = nil
  @AppStorage("theater.actionBar") private var actionsEnabled = true
  @State private var showEngagement = false
  @State private var bulletSettings = false
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    ZStack {
      // The backdrop fades in as the picture grows and out as it shrinks back into the page.
      Color.black.opacity(expanded ? 1 : 0).ignoresSafeArea()
      if stage == .shown {
        TheaterWorkspace(open: drawer && !locked) { playback } panel: {
          TheaterTools(model: model, subject: subject, playlist: playlist, close: { drawer = false },bulletSnapshot:{bulletInspector.snapshot?() ?? []})
            .id(subject?.type)
        }
        // The safe-area bands (notch / home indicator) stay black in landscape.
        .background { Color.black.ignoresSafeArea() }
      }
      if stage != .shown || bridge {
        // Only the picture moves between the inline player and fullscreen.
        GeometryReader { g in
          let full = CGRect(origin: .zero, size: g.size)
          let r = expanded ? full : (frameFrom ?? full)
          PlayerPictureLayer(player: model.engine)
            .frame(width: max(1, r.width), height: max(1, r.height))
            .offset(x: r.minX, y: r.minY)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
      }
    }
    .presentationBackground(.clear)
    .onAppear { enter() }
    .onChange(of: closeRequest) { _, _ in close() }
  }
  private func enter() {
    guard let from = origin?(), from.width > 20, from.height > 20 else {
      expanded = true
      stage = .shown
      covered?(true)
      return
    }
    frameFrom = from
    DispatchQueue.main.async {
      withAnimation(.smooth(duration: 0.34)) {
        expanded = true
      } completion: {
        // The full player takes over under the moving picture, which then fades away.
        bridge = true
        stage = .shown
        covered?(true)
        Task { @MainActor in
          try? await Task.sleep(for: .milliseconds(200))
          withAnimation(.easeOut(duration: 0.15)) { bridge = false }
        }
      }
    }
  }
  /// Leave without the cover's slide: rotate upright first (still covering the page), then
  /// shrink the picture back into the inline player while the backdrop fades out.
  private func close() {
    guard !closing else { return }
    closing = true
    covered?(false)
    TheaterExit.restore {
      guard let to = origin?(), to.width > 20, to.height > 20 else {
        finish()
        return
      }
      frameFrom = to
      bridge = true
      stage = .shrinking
      withAnimation(.smooth(duration: 0.32)) {
        expanded = false
      } completion: {
        finish()
      }
    }
  }
  private func finish() {
    var t = Transaction()
    t.disablesAnimations = true
    withTransaction(t) { dismiss() }
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
  /// The original client's fullscreen layout, filled with native controls.
  private var slots: PlayerChromeSlots {
    PlayerChromeSlots(
      title: title,
      headerLeading: AnyView(
        HStack(spacing: 0) {
          Button { close() } label: { PlayerGlyph(symbol: "chevron.left", size: 20) }
            .accessibilityLabel("退出全屏")
          PlayerHomeButton()
        }),
      // The original's fullscreen header: send bullet, bullets on/off, bullet settings, picture
      // in picture, more (plus our timeline).
      headerTrailing: AnyView(
        HStack(spacing: 0) {
          if let cid = subject?.cid, let bvid = subject?.bvid {
            EpisodeBulletAction(cid: cid, bvid: bvid, model: model, glyph: true)
          }
          Button {
            TouchFeedback.light()
            showBullets.toggle()
          } label: {
            PlayerGlyph(symbol: showBullets ? "text.bubble.fill" : "text.bubble", dimmed: !showBullets)
          }.accessibilityLabel(showBullets ? "关闭弹幕" : "开启弹幕")
          Button { bulletSettings = true } label: { PlayerGlyph(symbol: "text.bubble.badge.gearshape") }
            .accessibilityLabel("弹幕设置")
          PlayerPiPButton(player: model.engine)
          Button {
            withAnimation(.snappy(duration: 0.3)) { showTimeline.toggle() }
          } label: {
            PlayerGlyph(symbol: "timeline.selection", dimmed: !showTimeline)
          }.accessibilityLabel("时间轴")
          Button {
            withAnimation(.snappy(duration: 0.3)) { drawer.toggle() }
          } label: {
            PlayerGlyph(symbol: "ellipsis")
          }.accessibilityLabel(drawer ? "关闭播放面板" : "更多")
        }),
      bottomTrailing: AnyView(
        HStack(spacing: 0) {
          PlayerCaptionMenu(session: model.captions)
          PlayerSpeedMenu(model: model)
          PlayerQualityMenu(model: model)
        }),
      bottomLeading: keyStep.map { step in AnyView(PlayerStepButtons(step: step)) },
      bottomEpisode: playlist == nil ? nil : AnyView(
        Button {
          withAnimation(.snappy(duration: 0.3)) { drawer = true }
        } label: {
          PlayerGlyph(symbol: "list.bullet")
        }.accessibilityLabel("选集")),
      underHeader: actionsEnabled ? engagement.map {
        AnyView(EngagementBar(item: $0).environment(\.engagementCompact, true))
      } : nil,
      edgeLeading: allowLock ? AnyView(
        PlayerEdgeButton(symbol: "lock.open.fill", label: "锁定播放控件") { toggleLock() }) : nil,
      edgeTrailing: allowCapture ? AnyView(
        CaptureButton(player: model.engine)
          .font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
          .frame(width: 44, height: 44)
          .piliGlass(in: RoundedRectangle(cornerRadius: 12, style: .continuous), interactive: true,
            fallback: AnyShapeStyle(Color.black.opacity(0.3)))) : nil)
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
        // Controls are hidden while locked; keep the unlock button where the lock was.
        HStack {
          PlayerEdgeButton(symbol: "lock.fill", label: "解锁播放控件") { toggleLock() }
          Spacer()
        }
        .padding(.horizontal, 14).offset(y: -16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .transition(.opacity)
      }
    }
    .animation(.smooth(duration: 0.25), value: locked)
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
      .background(
        TheaterGeometry(
          mode: FullscreenMode(rawValue: orientation) ?? .video,
          size: model.engine.playbackSize
        ).allowsHitTesting(false)
      )
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
