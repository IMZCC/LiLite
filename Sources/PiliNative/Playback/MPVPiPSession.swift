import AVKit
import UIKit

/// The same sample-buffer PiP contract as ios/Runner/PipPlugin.swift, without Flutter texture hooks.
@MainActor final class MPVPiPSession: NSObject, @preconcurrency AVPictureInPictureControllerDelegate,
  @preconcurrency AVPictureInPictureSampleBufferPlaybackDelegate {
  private weak var player: MPVPlayer?
  private let source = SourceView()
  private var controller: AVPictureInPictureController?
  private var frames: MPVPiPFrames?
  private var possible: NSKeyValueObservation?
  private var clock: Timer?
  private var timeout: Task<Void, Never>?
  private var backgroundCheck: Task<Void, Never>?
  private var pending = false
  private var starting = false
  private var backgroundOnStart = false
  private var automaticPending = false
  private var active = false
  private var hasFrame = false
  private var restoring = false
  private var requestedStop = false
  private var enteredBackground = false
  private var invalidated = false
  private var renderSize = CGSize.zero
  private var item: ObjectIdentifier?
  var keepsVideo: Bool { active || pending || automaticPending }
  private var autoEnter: Bool { UserDefaults.standard.bool(forKey: "play.autoPiP") }
  private final class SourceView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
  }
  init(player: MPVPlayer) {
    self.player = player
    super.init()
    guard AVPictureInPictureController.isPictureInPictureSupported() else { return }
    source.isUserInteractionEnabled = false
    source.display.videoGravity = .resizeAspect
    var timebase: CMTimebase?
    guard CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &timebase) == noErr, let timebase else { return }
    source.display.controlTimebase = timebase
    let frames = MPVPiPFrames(layer: source.display, timebase: timebase)
    frames.didEnqueue = { [weak self] in
      DispatchQueue.main.async { [weak self] in
        guard let self, !self.invalidated else { return }
        self.hasFrame = true
        self.update()
        self.startIfPossible()
      }
    }
    self.frames = frames
    let pip = AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: source.display, playbackDelegate: self))
    pip.delegate = self
    controller = pip
    possible = pip.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { [weak self] in self?.startIfPossible() }
    }
    NotificationCenter.default.addObserver(self, selector: #selector(startRequested(_:)), name: .piliStartPictureInPicture, object: player)
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.update() }
    }
    clock = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  func attach(to window: UIWindow) {
    guard !invalidated else { return }
    if source.window !== window {
      source.removeFromSuperview()
      // Must be attached and non-hidden for AVKit's automatic PiP eligibility.
      // It sits behind the app's root view, just like the Flutter source view.
      window.insertSubview(source, at: 0)
    }
    update()
    player?.renderer.refreshPiP()
  }
  func update() {
    guard !invalidated, let player, let frames else { return }
    let identity = player.playbackItem.map(ObjectIdentifier.init)
    if identity != item {
      item = identity
      hasFrame = false
      player.renderer.resetPiP()
    }
    let size = player.playbackSize
    if let window = source.window, size.width > 0, size.height > 0 {
      let width = window.bounds.width
      source.frame = CGRect(x: 0, y: window.safeAreaInsets.top, width: width,
        height: min(window.bounds.height, width * size.height / size.width))
    }
    let playing = player.timeControlStatus == .playing
    CMTimebaseSetRateAndAnchorTime(frames.timebase, rate: playing ? Double(player.rate) : 0,
      anchorTime: player.currentTime(), immediateSourceTime: CMClockGetTime(CMClockGetHostTimeClock()))
    controller?.canStartPictureInPictureAutomaticallyFromInline = autoEnter && hasFrame && player.playbackReady && !player.audioOnly
    controller?.invalidatePlaybackState()
    player.renderer.configurePiP(frames, source: size, render: renderSize, active: active,
      enabled: !player.audioOnly && player.playbackReady && (UIApplication.shared.applicationState == .active || keepsVideo))
  }
  @objc private func startRequested(_ note: Notification) {
    guard !invalidated, let player, player.playbackReady, !player.audioOnly, let controller else {
      fail(); return
    }
    if active { requestedStop = true; controller.stopPictureInPicture(); return }
    guard !pending else { return }
    pending = true
    backgroundOnStart = true
    update()
    player.renderer.refreshPiP()
    startIfPossible()
    timeout?.cancel()
    timeout = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(2)) } catch { return }
      guard let self, self.pending else { return }
      self.fail()
    }
  }
  private func startIfPossible() {
    guard pending, !starting, hasFrame, controller?.isPictureInPicturePossible == true else { return }
    starting = true
    controller?.startPictureInPicture()
  }
  func willResignActive() {
    update()
    automaticPending = autoEnter && hasFrame && player?.rate != 0 && controller?.isPictureInPicturePossible == true
    update()
  }
  func didEnterBackground() {
    enteredBackground = true
    backgroundCheck?.cancel()
    // Allow AVKit's automatic transition to finish before applying the normal pause policy.
    backgroundCheck = Task { @MainActor [weak self] in
      do { try await Task.sleep(for: .seconds(1)) } catch { return }
      guard let self, self.enteredBackground else { return }
      self.automaticPending = false
      self.update()
      self.player?.refreshBackgroundPolicy()
    }
  }
  func didBecomeActive() {
    backgroundCheck?.cancel()
    automaticPending = false
    if enteredBackground && active {
      requestedStop = true
      controller?.stopPictureInPicture()
    }
    enteredBackground = false
    update()
  }
  private func setActive(_ value: Bool) {
    active = value
    if let player {
      PictureSession.shared(player).setPictureInPicture(value)
      NotificationCenter.default.post(name: VideoTransport.pipChanged, object: player)
      player.refreshBackgroundPolicy(allowPause: value)
    }
    update()
  }
  private func fail() {
    pending = false
    starting = false
    backgroundOnStart = false
    automaticPending = false
    timeout?.cancel()
    setActive(false)
    if UIApplication.shared.applicationState == .active, let player {
      NotificationCenter.default.post(name: .piliMPVPiPError, object: player)
    }
  }
  func stopPlayback() {
    requestedStop = true
    pending = false
    starting = false
    backgroundOnStart = false
    automaticPending = false
    timeout?.cancel()
    backgroundCheck?.cancel()
    controller?.canStartPictureInPictureAutomaticallyFromInline = false
    controller?.stopPictureInPicture()
    setActive(false)
    hasFrame = false
    player?.renderer.resetPiP()
  }
  func invalidate() {
    guard !invalidated else { return }
    invalidated = true
    timeout?.cancel()
    backgroundCheck?.cancel()
    clock?.invalidate()
    clock = nil
    possible = nil
    NotificationCenter.default.removeObserver(self)
    requestedStop = true
    controller?.stopPictureInPicture()
    controller?.delegate = nil
    controller?.contentSource = nil // AVKit retains the sample-buffer playback delegate.
    controller = nil
    source.removeFromSuperview()
    setActive(false)
  }
  func pictureInPictureControllerWillStartPictureInPicture(_ c: AVPictureInPictureController) {
    pending = false
    starting = false
    automaticPending = false
    timeout?.cancel()
    requestedStop = false
    restoring = false
    setActive(true)
    player?.renderer.refreshPiP()
  }
  func pictureInPictureControllerDidStartPictureInPicture(_ c: AVPictureInPictureController) {
    guard backgroundOnStart else { return }
    backgroundOnStart = false
    // Preserve the manual-enter behavior of Flutter PipPlugin.suspendApplication().
    UIControl().sendAction(#selector(URLSessionTask.suspend), to: UIApplication.shared, for: nil)
  }
  func pictureInPictureController(_ c: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) { fail() }
  func pictureInPictureController(_ c: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    restoring = source.window != nil && player?.playbackItem != nil
    completionHandler(restoring)
  }
  func pictureInPictureControllerDidStopPictureInPicture(_ c: AVPictureInPictureController) {
    let pause = MPVPiPPolicy.pauseOnClose(restoring: restoring, requested: requestedStop,
      background: UIApplication.shared.applicationState != .active, continuePlaying: player?.backgroundPlaybackAllowed ?? false)
    pending = false
    automaticPending = false
    setActive(false)
    restoring = false
    requestedStop = false
    if pause { player?.pause() }
  }
  func pictureInPictureController(_ c: AVPictureInPictureController, setPlaying playing: Bool) {
    if playing { player?.play() } else { player?.pause() }
    update()
  }
  func pictureInPictureControllerTimeRangeForPlayback(_ c: AVPictureInPictureController) -> CMTimeRange {
    let duration = player?.playbackDuration ?? 0
    return CMTimeRange(start: .zero, duration: duration > 0 ? CMTime(seconds: duration, preferredTimescale: 600) : .positiveInfinity)
  }
  func pictureInPictureControllerIsPlaybackPaused(_ c: AVPictureInPictureController) -> Bool { (player?.rate ?? 0) == 0 }
  func pictureInPictureController(_ c: AVPictureInPictureController, didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    let scale = source.window?.screen.scale ?? UIScreen.main.scale
    renderSize = CGSize(width: CGFloat(newRenderSize.width) * scale, height: CGFloat(newRenderSize.height) * scale)
    update()
    player?.renderer.refreshPiP()
  }
  func pictureInPictureController(_ c: AVPictureInPictureController, skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void) {
    guard let player, skipInterval.isNumeric else { completionHandler(); return }
    let time = player.currentTime() + skipInterval
    player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
      self?.update()
      completionHandler()
    }
    update()
  }
  func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(_ c: AVPictureInPictureController) -> Bool { false }
}

extension Notification.Name {
  static let piliMPVPiPError = Notification.Name("PiliNative.mpvPiPError")
}
