import AVFoundation
import Combine
import SwiftUI

@MainActor final class ViewportReadout: ObservableObject {
  @Published fileprivate(set) var seconds = 0.0
  @Published fileprivate(set) var buffers: [ClosedRange<Double>] = []
}

@MainActor final class ViewportClock: ObservableObject {
  let readout = ViewportReadout()
  @Published private(set) var pictureSize = CGSize.zero
  @Published private(set) var duration = 0.0
  @Published private(set) var playing = false
  @Published private(set) var ready = false
  @Published private(set) var item: ObjectIdentifier?
  private(set) var picture = PictureSession()
  private var pictureWatch: AnyCancellable?
  private var seekWatch: AnyCancellable?
  private var itemWatch: AnyCancellable?
  private var stateWatch: AnyCancellable?
  private weak var source: (any PlaybackEngine)?
  private var timer: Timer?
  private var publishedAt = -Double.infinity
  func attach(_ player: any PlaybackEngine) {
    guard source !== player else { return }
    close()
    source = player
    picture = PictureSession.shared(player)
    pictureWatch = picture.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    seekWatch = picture.seekChanged.sink { [weak self] _ in self?.sample(immediate: true) }
    itemWatch = player.itemPublisher.sink { [weak self] _ in self?.sample(immediate: true) }
    stateWatch = player.statePublisher.sink { [weak self] _ in self?.sample() }
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.sample() }
    }
    self.timer = timer
    RunLoop.main.add(timer, forMode: .common)
    sample(immediate: true)
  }
  private func sample(immediate: Bool = false) {
    guard let player = source else { return }
    let identity = player.playbackItem.map(ObjectIdentifier.init)
    if item != identity { item = identity }
    if ready != player.playbackReady { ready = player.playbackReady }
    let active = player.timeControlStatus != .paused
    if playing != active { playing = active }
    let size = player.playbackSize
    if pictureSize != size { pictureSize = size }
    let d = player.playbackDuration
    let length = d.isFinite && d > 0 && d < Double(Int.max) ? d : 0
    if duration != length { duration = length }
    let t = picture.target(for: player.playbackItem) ?? player.currentTime().seconds
    let now = t.isFinite && t >= 0 && t < Double(Int.max) ? t : 0
    let host = ProcessInfo.processInfo.systemUptime
    guard immediate || host - publishedAt >= 0.25 else { return }
    publishedAt = host
    if readout.seconds != now { readout.seconds = now }
    let ranges = player.playbackBuffers
    if readout.buffers != ranges { readout.buffers = ranges }
  }
  func close() {
    timer?.invalidate()
    timer = nil
    pictureWatch = nil
    seekWatch = nil
    itemWatch = nil
    stateWatch = nil
    source = nil
    publishedAt = -Double.infinity
    item = nil
    pictureSize = .zero
    ready = false
    readout.buffers = []
    readout.seconds = 0
    duration = 0
    playing = false
  }
}

@MainActor final class ViewportTouch: ObservableObject {
  @Published var horizontalSeek: Double?
  var pinching = false, ignorePanBefore = 0.0
  var lastBulletTap = -Double.infinity
  var acceptsPan: Bool { !pinching && ProcessInfo.processInfo.systemUptime >= ignorePanBefore }
}
private enum ViewportTouchKey: EnvironmentKey { static let defaultValue: ViewportTouch? = nil }
extension EnvironmentValues {
  var viewportTouch: ViewportTouch? {
    get { self[ViewportTouchKey.self] }
    set { self[ViewportTouchKey.self] = newValue }
  }
}

struct ViewportSeekBar: View {
  let clock: ViewportClock
  @ObservedObject var readout: ViewportReadout
  let seek: (Double) -> Void, editing: (Bool) -> Void
  let compact: Bool
  var external: Double?
  var marks: AnyView? = nil
  var timeline:TimelineState?=nil
  @AppStorage("player.seekPreview") private var previews=true
  @State private var drag: Double?
  private var time: Double { drag ?? external ?? readout.seconds }
  var body: some View {
    GeometryReader { g in
      let w = max(1, g.size.width)
      let total = max(0.01, clock.duration)
      let fraction = min(1, max(0, time / total))
      let buffers = readout.buffers
      // Original-client proportions: a 3.5 pt bar, buffered span in a translucent accent,
      // played span in the accent, and a 14 pt accent thumb that glows while dragging.
      let height: CGFloat = compact && drag == nil ? 2.5 : 3.5
      let center = compact ? g.size.height - height / 2 : g.size.height / 2
      ZStack {
        Capsule().fill(.white.opacity(0.2)).frame(height: height).position(x: w / 2, y: center)
        ForEach(buffers.indices, id: \.self) { i in
          let span = buffers[i]
          let lo = min(1, max(0, span.lowerBound / total))
          let hi = min(1, max(0, span.upperBound / total))
          Capsule().fill(Color.accentColor.opacity(0.4)).frame(width: (hi - lo) * w, height: height)
            .position(x: (lo + hi) / 2 * w, y: center)
        }
        Capsule().fill(Color.accentColor).frame(width: fraction * w, height: height).position(
          x: fraction * w / 2, y: center)
        if let timeline {
          ArchiveTrendStrip(timeline:timeline,duration:clock.duration).frame(width:w,height:15)
            .position(x:w/2,y:center-8)
        }
        if let marks {
          marks.frame(width: w, height: 3).position(x: w / 2, y: center).allowsHitTesting(false)
        }
        if previews,let drag,let timeline{
          ShotPreview(state:timeline,seconds:drag).frame(width:min(128,w),height:72)
            .position(x:min(max(min(64,w/2),fraction*w),max(w/2,w-64)),y:center-56)
        }
        if let drag {
          Text(clockText(drag)).font(.caption.monospacedDigit()).foregroundStyle(.white).padding(3)
            .background(.black.opacity(0.8), in: Capsule())
            .position(x: min(max(20, w - 24), max(24, fraction * w)), y: center - 17)
            .allowsHitTesting(false)
        }
        if !compact || drag != nil {
          let knob = min(w - 7, max(7, fraction * w))
          if drag != nil {
            Circle().fill(Color.accentColor.opacity(0.25)).frame(width: 40, height: 40)
              .position(x: knob, y: center).allowsHitTesting(false)
          }
          Circle().fill(Color.accentColor).frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            .position(x: knob, y: center)
        }
      }.contentShape(Rectangle())
        .gesture(
          DragGesture(minimumDistance: 0).onChanged { v in
            guard clock.duration > 0 else { return }
            if drag == nil { TouchFeedback.light(); editing(true) }
            drag = min(1, max(0, v.location.x / w)) * clock.duration
          }.onEnded { v in
            if clock.duration > 0 { seek(min(1, max(0, v.location.x / w)) * clock.duration) }
            drag = nil
            editing(false)
          })
    }.frame(height: compact ? 20 : 30)
      .accessibilityElement(children: .ignore).accessibilityLabel("播放进度")
      .accessibilityValue(clockText(time) + "，共" + clockText(clock.duration))
      .accessibilityAdjustableAction { direction in
        guard clock.duration > 0 else { return }
        TouchFeedback.light()
        let step = max(1, UserDefaults.standard.object(forKey: "player.seekStep") as? Double ?? 10)
        seek(min(clock.duration, max(0, time + (direction == .increment ? step : -step))))
        editing(false)
      }.onDisappear {
        if drag != nil {
          drag = nil
          editing(false)
        }
      }
  }
}

struct ViewportMarks: View {
  @ObservedObject var model: PlayerModel
  @ObservedObject private var timeline: TimelineState
  @AppStorage("detail.chapters") private var chapters = true
  init(model: PlayerModel) {
    self.model = model
    timeline = model.timeline
  }
  var body: some View {
    ZStack {
      if !model.sponsor.isEmpty {
        SponsorMarkers(rows: model.sponsor, duration: model.duration, rules: model.sponsorRules)
      }
      if chapters,timeline.showChapterMarks, model.duration > 0 {
        Canvas { ctx, size in
          for t in timeline.chapterStarts where t < model.duration {
            let x = size.width * (t / model.duration)
            ctx.fill(
              Path(CGRect(x: x, y: 0, width: 1.5, height: size.height)), with: .color(.white))
          }
        }
      }
    }.accessibilityHidden(true)
  }
}

struct ViewportTimeLabel: View {
  @ObservedObject var readout: ViewportReadout
  let external: Double?, duration: Double
  var body: some View {
    Text(clockText(external ?? readout.seconds) + " / " + clockText(duration))
      .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.92)).fixedSize()
  }
}
