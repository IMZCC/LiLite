import AVFoundation
import SwiftUI

struct PlayerGestures: View {
  @ObservedObject var model: PlayerModel
  var inspector: BulletInspector? = nil
  var enterTheater: (() -> Void)? = nil
  var fullscreen = false
  var body:some View {
    GestureCanvas(model:.init(player:model.engine,model:model),inspector:inspector,enterTheater:enterTheater,fullscreen:fullscreen)
  }
}
struct FilePlayerGestures:View{
  let player: any PlaybackEngine
  let inspector: BulletInspector?
  let exit: () -> Void
  var body:some View{GestureCanvas(model:.init(player:player,model:nil),inspector:inspector,enterTheater:exit,fullscreen:true)}
}
@MainActor private struct GestureMedia {
  let player: any PlaybackEngine
  let model: PlayerModel?
  var seconds:Double{let value=player.currentTime().seconds;return model?.seconds ?? (value.isFinite ? max(0,value):0)}
  var duration:Double{let value=player.playbackDuration;return model?.duration ?? (value.isFinite ? max(0,value):0)}
  var ready:Bool{model?.ready ?? (player.playbackReady && duration>0)}
  var playing:Bool{player.rate != 0}
  var rate:Float{player.defaultRate}
  func toggle(){if let model{model.toggle()}else if playing{player.pause()}else if duration>0 && seconds>=duration-0.4,let item=player.playbackItem{Task{await quickSeek(-seconds,item:item)}}else{player.play()}}
  func seek(_ v:Double){if let model{model.seek(v)}else{if let native = player.nativePlayer { OfflineDecoderItem.aboutToSeek(native,to:v) };player.seek(to:.init(seconds:v,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero)}}
  func quickSeek(_ delta:Double,item:AnyObject)async{
    if let model{await model.quickSeek(delta,item:item);return}
    guard ready,player.playbackItem===item else{return}
    let value=min(duration,max(0,seconds+delta));if let native = player.nativePlayer { OfflineDecoderItem.aboutToSeek(native,to:value) }
    if await player.seek(to:.init(seconds:value,preferredTimescale:600),toleranceBefore:.zero,toleranceAfter:.zero),!Task.isCancelled,player.playbackItem===item{player.playImmediately(atRate:player.defaultRate)}
  }
}
private struct GestureCanvas:View{
  let model:GestureMedia,inspector:BulletInspector?,enterTheater:(()->Void)?,fullscreen:Bool
  @AppStorage("dm.tap") private var inspectBullets=true
  @Environment(\.scenePhase) private var scene
  @Environment(\.viewportTouch) private var viewportTouch
  @AppStorage("theater.swipe") private var screenSwipe = true
  @AppStorage("theater.reverseSwipe") private var reverseSwipe = false
  @State private var axis: PlayerSlide.Axis?
  @State private var switchedScreen = false
  @State private var burst = 0.0
  @State private var burstEnd: Task<Void,Never>?
  @State private var boostedItem: AnyObject?
  @State private var start: Double?
  @State private var feedback: String?
  /// Volume / brightness while sliding: shown as the original's centred icon pill.
  @State private var level: (symbol: String, percent: Int)?
  @State private var scrub: Double?
  @AppStorage("player.seekPreview") private var preview = true
  @State private var levelTracker: PlayerSlide.LevelTracker?
  /// Detents felt while sliding the position, brightness or volume.
  @State private var detents = SlideDetents()
  /// Off by default: the official client's double tap pauses or resumes anywhere on the picture.
  @AppStorage("player.quickDouble") private var quick = false
  @AppStorage(PlayerSlide.seekCurveKey) private var seekCurve = true
  @AppStorage("player.slideLevels") private var slide = true
  @AppStorage("player.doubleSpeed") private var doubleSpeed = false
  @AppStorage("player.relativeSeek") private var relative = false
  @AppStorage("player.seekStep") private var step = 10.0
  @AppStorage("player.slideRange") private var range = 90.0
  @AppStorage("player.holdSpeed") private var hold = 3.0
  @State private var boost = false
  @State private var boostRate: Float?
  /// The double-tap jump just made, kept on screen a moment after it lands.
  @State private var echo: (time: Double, delta: Double)?
  @State private var echoEnd: Task<Void, Never>?
  @State private var clear: Task<Void, Never>?
  var body: some View {
    GeometryReader { g in
      ZStack {
        Color.clear.contentShape(Rectangle())
          .onTapGesture(count: 2, coordinateSpace: .local) { loc in
            guard model.ready else { return }
            if quick, PlayerTouchZone.doubleTap(loc.x,width:g.size.width) == .back {
              accumulate(-step)
            } else if quick, PlayerTouchZone.doubleTap(loc.x,width:g.size.width) == .forward {
              accumulate(step)
            } else {
              // As the official client: pausing by double tap in fullscreen also brings up the
              // controls, so play and the progress are right there.
              let pausing = model.playing
              model.toggle()
              if pausing && fullscreen { viewportTouch?.reveal?() }
            }
          }
          .onTapGesture(count:1,coordinateSpace:.local){p in
            if let inspector{let hadPick=inspector.pick != nil;inspector.select(p)
              if hadPick || inspector.pick != nil{viewportTouch?.lastBulletTap=ProcessInfo.processInfo.systemUptime}
            }
          }
          .onLongPressGesture(
            // The official client's (BBPlayerGestureService, 8.89): 0.25 s, within UIKit's default
            // 10 pt; a finger that travels farther first is a slide instead.
            minimumDuration: 0.25, maximumDistance: PlayerSlide.decisionDistance,
            perform: {
              // A finger already sliding (seek, brightness, volume) keeps sliding.
              if model.ready && model.playing && axis == nil {
                TouchFeedback.light()
                boost = true
                boostedItem = model.player.playbackItem
                let speed = doubleSpeed ? model.rate * 2 : Float(hold)
                model.player.rate = speed
                boostRate = speed
              }
            },
            onPressingChanged: { down in
              if !down && boost {
                endBoost()
                hint(nil)
              }
            }
          )
          .simultaneousGesture(
            DragGesture(minimumDistance: 1).onChanged { v in
              guard model.ready else { return }
              guard viewportTouch?.acceptsPan != false else {
                start = nil; axis = nil
                scrub = nil
                feedback = nil
                return
              }
              // Holding for double speed owns the touch until the finger lifts: moving it while
              // held never turns into a seek, as in the official client.
              if boost {
                if start != nil || axis != nil { start = nil; axis = nil; scrub = nil; levelTracker = nil; level = nil }
                return
              }
              let dx = v.translation.width, dy = v.translation.height
              if axis == nil {
                // A resting finger trembles a few points: the direction is only read once it has
                // really moved.
                guard hypot(dx, dy) >= PlayerSlide.decisionDistance else { return }
                axis = PlayerSlide.axis(dx: dx, dy: dy, x: v.startLocation.x, width: g.size.width, levels: slide, screen: screenSwipe)
              }
              guard let axis else { return }
              if start == nil {
                switchedScreen = false
                start = model.seconds; clear?.cancel()
                switch axis {
                case .brightness: levelTracker = .init(start: WindowMetrics.brightness, brightness: true)
                case .volume: levelTracker = .init(start: Double(model.player.presentationVolume), brightness: false)
                default: levelTracker = nil
                }
              }
              switch axis {
              case .seek:
                if PlayerSlide.cancelsSeek(v.location, size: g.size) {
                  scrub = nil; feedback = "松开手指，取消进退"
                } else {
                  let t = target(dx, width: g.size.width)
                  scrub = t; feedback = nil
                  if model.duration > 0 {
                    detents.move(t / model.duration, origin: (start ?? t) / model.duration)
                  }
                }
              case .fullscreen:
                scrub = nil; feedback = nil
                if !switchedScreen, FullscreenMode.swipe(fullscreen: fullscreen, reverse: reverseSwipe,
                  x: v.startLocation.x, width: g.size.width, dx: dx, dy: dy) {
                  switchedScreen = true; TouchFeedback.light(); enterTheater?()
                }
              case .brightness:
                guard let n = levelTracker?.level(-dy / max(1, g.size.height)) else { break }
                WindowMetrics.brightness = n
                level = (PlayerLevelPill.brightnessSymbol(n), Int((n * 100).rounded()))
                detents.move(n)
              case .volume:
                guard let n = levelTracker?.level(-dy / max(1, g.size.height)) else { break }
                model.player.presentationVolume = Float(n)
                level = (PlayerLevelPill.volumeSymbol(n), Int((n * 100).rounded()))
                detents.move(n)
              }
            }.onEnded { v in
              guard viewportTouch?.acceptsPan != false else {
                start = nil; axis = nil
                scrub = nil
                hint(nil)
                return
              }
              if start != nil, axis == .seek, !PlayerSlide.cancelsSeek(v.location, size: g.size) {
                TouchFeedback.light()
                model.seek(target(v.translation.width, width: g.size.width))
              }
              start = nil; axis = nil; levelTracker = nil
              scrub = nil
              level = nil
              detents.finish()
              hint(nil)
            })
        if burst != 0 {
          // More taps on the same half keep adding to the jump.
          HStack(spacing: 0) {
            if burst > 0 { Spacer() }
            Button {
              accumulate(burst > 0 ? step : -step)
            } label: {
              Color.clear.contentShape(Rectangle())
            }.buttonStyle(.plain).frame(width: g.size.width / 2)
            if burst < 0 { Spacer() }
          }
        }
        // All gesture feedback is one glass capsule at the top centre.
        VStack(spacing: 8) {
          if burst != 0 {
            PlayerSeekHUD(time: min(model.duration, max(0, model.seconds + burst)), duration: model.duration, delta: burst)
          } else if let echo {
            PlayerSeekHUD(time: echo.time, duration: model.duration, delta: echo.delta)
          } else if let scrub {
            PlayerSeekHUD(time: scrub, duration: model.duration, delta: scrub - (start ?? scrub))
            if preview, let timeline = model.model?.timeline { ShotPreview(state: timeline, seconds: scrub) }
          } else if let level {
            PlayerLevelHUD(symbol: level.symbol, percent: level.percent)
          } else if let boostRate {
            PlayerRateHUD(rate: boostRate)
          } else if let feedback {
            PlayerHUDCapsule {
              Text(feedback).font(.system(size: 14, weight: .medium))
            }
          }
          Spacer(minLength: 0)
        }
        .padding(.top, fullscreen ? 26 : 10)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.18), value: burst != 0 || echo != nil)
        .animation(.easeOut(duration: 0.18), value: scrub == nil)
        .animation(.easeOut(duration: 0.18), value: level == nil)
        .animation(.easeOut(duration: 0.18), value: boostRate)
        .animation(.easeOut(duration: 0.18), value: feedback)
      }
    }.accessibilityHidden(true).onChange(of: scrub) { _, t in viewportTouch?.horizontalSeek = t }
      .onChange(of:scene){_,state in if state != .active{cancel()}}
      .onReceive(model.player.itemPublisher.dropFirst()){_ in cancel()}
      .onDisappear{cancel()}
  }
  private func cancel(){detents.finish();level=nil;viewportTouch?.horizontalSeek=nil;clear?.cancel();burstEnd?.cancel();echoEnd?.cancel();echo=nil;burst=0;start=nil;axis=nil;scrub=nil;feedback=nil;endBoost()}
  private func accumulate(_ delta: Double) {
    guard let item = model.player.playbackItem, model.ready, delta.isFinite, delta != 0 else { return }
    burstEnd?.cancel()
    burst = ((burst > 0) == (delta > 0) ? burst : 0) + delta
    let requested = burst
    echoEnd?.cancel()
    echo = nil
    burstEnd = Task { @MainActor in
      do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      echo = (min(model.duration, max(0, model.seconds + requested)), requested)
      burst = 0
      echoEnd = Task { @MainActor in
        do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
        echo = nil
      }
      guard model.player.playbackItem === item, model.ready else { return }
      await model.quickSeek(requested, item: item)
    }
  }
  private func endBoost() {
    boostRate = nil
    guard boost else { return }
    boost = false
    if boostedItem === model.player.playbackItem, model.player.rate != 0 { model.player.rate = model.rate }
    boostedItem = nil
  }
  private func target(_ dx: Double, width: Double) -> Double {
    let span = seekCurve ? PlayerSlide.seekSpan(duration: model.duration)
      : relative ? model.duration * range / 100 : range
    return min(model.duration, max(0, (start ?? model.seconds) + dx / max(1, width) * span))
  }
  private func hint(_ text: String?) {
    clear?.cancel()
    feedback = text
    if text != nil {
      clear = Task {
        try? await Task.sleep(nanoseconds: 800_000_000)
        if !Task.isCancelled { feedback = nil }
      }
    }
  }
}
