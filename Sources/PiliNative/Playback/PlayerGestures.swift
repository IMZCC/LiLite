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
  @State private var originBrightness = 0.5
  @State private var originVolume: Float = 1
  @AppStorage("player.quickDouble") private var quick = true
  @AppStorage("player.slideLevels") private var slide = true
  @AppStorage("player.doubleSpeed") private var doubleSpeed = false
  @AppStorage("player.relativeSeek") private var relative = false
  @AppStorage("player.seekStep") private var step = 10.0
  @AppStorage("player.slideRange") private var range = 90.0
  @AppStorage("player.holdSpeed") private var hold = 3.0
  @State private var boost = false
  @State private var clear: Task<Void, Never>?
  var body: some View {
    GeometryReader { g in
      ZStack {
        Color.clear.contentShape(Rectangle())
          .onTapGesture(count: 2, coordinateSpace: .local) { loc in
            guard model.ready else { return }
            if !quick {
              model.toggle()
              return
            }
            if PlayerTouchZone.doubleTap(loc.x,width:g.size.width) == .back {
              accumulate(-step)
            } else if PlayerTouchZone.doubleTap(loc.x,width:g.size.width) == .forward {
              accumulate(step)
            } else {
              model.toggle()
            }
          }
          .onTapGesture(count:1,coordinateSpace:.local){p in
            if let inspector{let hadPick=inspector.pick != nil;inspector.select(p)
              if hadPick || inspector.pick != nil{viewportTouch?.lastBulletTap=ProcessInfo.processInfo.systemUptime}
            }
          }
          .onLongPressGesture(
            minimumDuration:inspectBullets ? 0.30:0.50, maximumDistance: 15,
            perform: {
              if model.ready && model.playing {
                TouchFeedback.light()
                boost = true
                boostedItem = model.player.playbackItem
                let speed = doubleSpeed ? model.rate * 2 : Float(hold)
                model.player.rate = speed
                feedback = "\(speed.formatted())倍速中"
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
              let dx = v.translation.width, dy = v.translation.height
              if axis == nil {
                axis = PlayerSlide.axis(dx: dx, dy: dy, x: v.startLocation.x, width: g.size.width, levels: slide, screen: screenSwipe)
              }
              guard let axis else { return }
              if start == nil {
                switchedScreen = false
                start = model.seconds; originVolume = model.player.presentationVolume
                originBrightness = UIScreen.main.brightness; clear?.cancel()
              }
              switch axis {
              case .seek:
                let t = target(dx, width: g.size.width)
                scrub = t; feedback = clockText(t) + "/" + clockText(model.duration)
              case .fullscreen:
                scrub = nil; feedback = nil
                if !switchedScreen, FullscreenMode.swipe(fullscreen: fullscreen, reverse: reverseSwipe,
                  x: v.startLocation.x, width: g.size.width, dx: dx, dy: dy) {
                  switchedScreen = true; TouchFeedback.light(); enterTheater?()
                }
              case .brightness:
                let n = PlayerSlide.level(originBrightness, dy: dy, height: g.size.height, brightness: true)
                UIScreen.main.brightness = n
                level = (PlayerLevelPill.brightnessSymbol(n), Int((n * 100).rounded()))
              case .volume:
                let n = PlayerSlide.level(Double(originVolume), dy: dy, height: g.size.height, brightness: false)
                model.player.presentationVolume = Float(n)
                level = (PlayerLevelPill.volumeSymbol(n), Int((n * 100).rounded()))
              }
            }.onEnded { v in
              guard viewportTouch?.acceptsPan != false else {
                start = nil; axis = nil
                scrub = nil
                hint(nil)
                return
              }
              if start != nil, axis == .seek {
                TouchFeedback.light()
                model.seek(target(v.translation.width, width: g.size.width))
              }
              start = nil; axis = nil
              scrub = nil
              level = nil
              hint(nil)
            })
        if burst != 0 {
          HStack(spacing: 0) {
            if burst > 0 { Spacer() }
            Button {
              accumulate(burst > 0 ? step : -step)
            } label: {
              ZStack {
                Rectangle().fill(Color.black.opacity(0.25))
                Label("\(Int(abs(burst))) 秒", systemImage: burst > 0 ? "forward.fill" : "backward.fill")
                  .font(.headline.monospacedDigit()).foregroundStyle(.white)
              }
            }.buttonStyle(.plain).frame(width: g.size.width / 2)
            if burst < 0 { Spacer() }
          }
        }
        if let level {
          PlayerLevelPill(symbol: level.symbol, percent: level.percent)
        }
        // Long-press speed and drag-seek time sit near the top, as in the original.
        if let feedback {
          VStack(spacing: 6) {
            PlayerTopToast(text: feedback, rounded: scrub == nil ? 16 : 32)
            if preview,let scrub,let timeline=model.model?.timeline{ShotPreview(state:timeline,seconds:scrub)}
            Spacer(minLength: 0)
          }
          .padding(.top, fullscreen ? 44 : 26)
          .modifier(ToastAlpha()).allowsHitTesting(false)
        }
      }
    }.accessibilityHidden(true).onChange(of: scrub) { _, t in viewportTouch?.horizontalSeek = t }
      .onChange(of:scene){_,state in if state != .active{cancel()}}
      .onReceive(model.player.itemPublisher.dropFirst()){_ in cancel()}
      .onDisappear{cancel()}
  }
  private func cancel(){level=nil;viewportTouch?.horizontalSeek=nil;clear?.cancel();burstEnd?.cancel();burst=0;start=nil;axis=nil;scrub=nil;feedback=nil;endBoost()}
  private func accumulate(_ delta: Double) {
    guard let item = model.player.playbackItem, model.ready, delta.isFinite, delta != 0 else { return }
    burstEnd?.cancel()
    burst = ((burst > 0) == (delta > 0) ? burst : 0) + delta
    let requested = burst
    burstEnd = Task { @MainActor in
      do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
      burst = 0
      guard model.player.playbackItem === item, model.ready else { return }
      await model.quickSeek(requested, item: item)
    }
  }
  private func endBoost() {
    guard boost else { return }
    boost = false
    if boostedItem === model.player.playbackItem, model.player.rate != 0 { model.player.rate = model.rate }
    boostedItem = nil
  }
  private func target(_ dx: Double, width: Double) -> Double {
    min(
      model.duration,
      max(
        0,
        (start ?? model.seconds) + dx / max(1, width)
          * (relative ? model.duration * range / 100 : range)))
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
