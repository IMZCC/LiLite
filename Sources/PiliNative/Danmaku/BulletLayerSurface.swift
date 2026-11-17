import AVFoundation
import Combine
import SwiftUI
import UIKit

struct BulletScene {
  let id = UUID()
  let plan: BulletLayoutPlan, style: DanmakuStyle, point: CGFloat, scale: CGFloat
}

/// Core Animation moves glyphs on the item's actual timebase, including waits, seeks and rate changes.
/// The main thread only admits/releases rows near the playhead; no display-link or per-frame text drawing.
struct BulletLayerSurface: UIViewRepresentable {
  let scene: BulletScene?
  let player: (any PlaybackEngine)?
  let inspector: BulletInspector?
  let fps: Int
  func makeUIView(context: Context) -> Surface { Surface() }
  func updateUIView(_ view: Surface, context: Context) { view.configure(scene, player, inspector, fps) }
  static func dismantleUIView(_ view: Surface, coordinator: ()) { view.close() }

  final class Surface: UIView {
    private enum Row: Hashable, Sendable { case regular(Int), special(Int) }
    private struct Shift: Equatable { let sample: Double, resume: Double? }
    private struct Node { let layer: CALayer, raster: BulletRasterCache.Raster; var shift: Shift? }
    private var scene: BulletScene?, nodes = [Row: Node](), wanted = Set<Row>(), failed = Set<Row>()
    private weak var player: (any PlaybackEngine)?
    private weak var inspector: BulletInspector?
    private var sync: CALayer?
    private var timer: Any?
    private var itemWatch: AnyCancellable?
    private var stateWatch: AnyCancellable?
    private weak var boundItem: AnyObject?
    private var jump: NSObjectProtocol?, picks: AnyCancellable?
    private var worker: Task<Void, Never>?, ticket = UUID(), lastSize = CGSize.zero, fps = 0
    private var shifts = [Row: Shift]()
    override init(frame: CGRect) {
      super.init(frame: frame)
      isOpaque = false; backgroundColor = .clear; clipsToBounds = true; isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { nil }
    func configure(_ next: BulletScene?, _ source: (any PlaybackEngine)?, _ picker: BulletInspector?, _ frequency: Int) {
      if player !== source {
        close()
        player = source
        if let source {
          itemWatch = source.itemPublisher.dropFirst().sink { [weak self] _ in
            Task { @MainActor in self?.attachItem() }
          }
        }
      }
      let changed = scene?.id != next?.id || fps != frequency
      if changed { clearRows(); scene = next; fps = frequency }
      if inspector !== picker {
        inspector = picker
        picks = picker?.$pick.dropFirst().sink { [weak self] _ in
          // The published value precedes the inspector's pauseClock didSet.
          Task { @MainActor in self?.refresh() }
        }
      }
      attachItem()
      if changed { refresh() }
    }
    override func didMoveToWindow() { super.didMoveToWindow(); attachItem() }
    override func layoutSubviews() {
      super.layoutSubviews()
      guard lastSize != bounds.size else { return }
      lastSize = bounds.size
      CATransaction.begin(); CATransaction.setDisableActions(true); sync?.frame = bounds; CATransaction.commit()
      clearRows(); refresh()
    }
    private func attachItem() {
      let item = window == nil || scene == nil ? nil : player?.playbackItem
      guard boundItem !== item else { return }
      detachItem()
      guard let item, let player else { return }
      let timing: CALayer = (item as? AVPlayerItem).map { AVSynchronizedLayer(playerItem: $0) } ?? CALayer()
      boundItem = item
      timing.frame = bounds; layer.addSublayer(timing); sync = timing
      if player.engineKind == .mpv { stateWatch = player.statePublisher.sink { [weak self] _ in self?.syncClock() } }
      syncClock()
      timer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4), queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      }
      jump = NotificationCenter.default.addObserver(forName: player.engineKind == .mpv ? .piliEngineTimeJumped : .AVPlayerItemTimeJumped, object: item, queue: .main) {
        [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
      }
      refresh()
    }
    private func clearRows() {
      ticket = UUID(); worker?.cancel(); worker = nil
      nodes.values.forEach { $0.layer.removeFromSuperlayer() }
      nodes.removeAll(); wanted.removeAll(); failed.removeAll(); shifts.removeAll()
    }
    private func detachItem() {
      if let timer { player?.removeTimeObserver(timer) }; timer = nil
      if let jump { NotificationCenter.default.removeObserver(jump) }; jump = nil
      clearRows(); sync?.removeFromSuperlayer(); sync = nil; boundItem = nil; stateWatch = nil
    }
    func close() {
      detachItem(); itemWatch = nil; picks = nil; inspector = nil; scene = nil; player = nil
    }
    private func syncClock() {
      guard let player, player.engineKind == .mpv, let sync else { return }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      sync.speed = player.timeControlStatus == .playing ? player.rate : 0
      sync.timeOffset = player.currentTime().seconds
      sync.beginTime = CACurrentMediaTime()
      CATransaction.commit()
    }
    private func refresh() {
      guard let scene, let item = boundItem, item === player?.playbackItem, bounds.width > 0 else { return }
      syncClock()
      let now = player?.currentTime().seconds ?? 0
      guard now.isFinite else { return }
      let plan = scene.plan
      let rows = plan.regular(at: now, ahead: 1)
      let fx = plan.effects(at: now, ahead: 1)
      var order = rows.map(Row.regular) + fx.map(Row.special)
      var nextShifts = [Row: Shift]()
      if let inspector {
        for entry in inspector.pauseClock.entries where entry.position(at: now) < entry.until {
          let pick = entry.key
          let key: Row?
          if pick.bullet.special != nil {
            key = BulletOverlay.row(pick, in: plan.special, bullet: { $0 }).map(Row.special)
          } else {
            key = BulletOverlay.row(pick, in: plan.rows, bullet: { $0.bullet }).map(Row.regular)
          }
          if let key {
            nextShifts[key] = Shift(sample: entry.sample, resume: entry.resume)
            if !order.contains(key) { order.append(key) }
          }
        }
      }
      shifts = nextShifts
      wanted = Set(order); failed.formIntersection(wanted)
      CATransaction.begin(); CATransaction.setDisableActions(true)
      for (key, node) in nodes {
        if !wanted.contains(key) { node.layer.removeFromSuperlayer(); nodes[key] = nil }
        else if node.shift != shifts[key] { animate(key, node: node, scene: scene) }
      }
      CATransaction.commit()
      guard worker == nil else { return }
      let requests: [(Row, BulletRasterCache.Style)] = order.compactMap { key in
        guard nodes[key] == nil, !failed.contains(key) else { return nil }
        let b: Bullet, repeats: Int
        switch key {
        case .regular(let i): let p = plan.rows[i]; b = p.bullet; repeats = p.repeats
        case .special(let i): b = plan.special[i]; repeats = 1
        }
        return (key, BulletRasterCache.style(b, repeats: repeats, point: scene.point, layout: scene.style, scale: scene.scale))
      }
      guard !requests.isEmpty else { return }
      let token = ticket
      // One bounded producer; late results cannot install layers into another plan or player.
      worker = Task.detached(priority: .userInitiated) { [weak self] in
        var batch = [(Row, BulletRasterCache.Raster?)]()
        for (index, request) in requests.enumerated() {
          guard !Task.isCancelled else { return }
          let image = autoreleasepool { BulletRasterCache.shared.image(request.1) }
          batch.append((request.0, image))
          if batch.count == 6 || index + 1 == requests.count {
            await self?.install(batch, token: token); batch.removeAll(keepingCapacity: true)
          }
        }
        await self?.finished(token)
      }
    }
    private func finished(_ token: UUID) {
      guard ticket == token else { return }; worker = nil; refresh()
    }
    private func install(_ batch: [(Row, BulletRasterCache.Raster?)], token: UUID) {
      guard token == ticket, let scene, let sync else { return }
      CATransaction.begin(); CATransaction.setDisableActions(true)
      defer { CATransaction.commit() }
      for (key, raster) in batch where wanted.contains(key) && nodes[key] == nil {
        guard let raster else { failed.insert(key); continue }
        let plane = CALayer(), glyph = CALayer()
        plane.anchorPoint = .zero; glyph.anchorPoint = .zero
        glyph.contents = raster.image; glyph.contentsScale = raster.scale
        glyph.bounds = CGRect(origin: .zero, size: raster.size)
        switch key {
        case .regular(let i):
          let p = scene.plan.rows[i]
          plane.bounds.size = CGSize(width: p.width, height: scene.point * 1.3)
          plane.zPosition = CGFloat(i + 1)
          if p.mine {
            plane.borderColor = UIColor.green.cgColor; plane.borderWidth = max(0.5, scene.style.stroke)
            glyph.position.x = 2
          }
        case .special(let i):
          let sp = scene.plan.special[i].special!
          plane.zPosition = CGFloat(i) - CGFloat(scene.plan.special.count)
          glyph.position = CGPoint(x: -raster.inset, y: -raster.inset)
          plane.setAffineTransform(CGAffineTransform(rotationAngle: sp.angle * .pi / 180)
            .scaledBy(x: cos(sp.tilt * .pi / 180), y: 1))
        }
        plane.addSublayer(glyph); sync.addSublayer(plane)
        animate(key, node: Node(layer: plane, raster: raster), scene: scene)
      }
    }
    private func animate(_ key: Row, node: Node, scene: BulletScene) {
      let layer = node.layer, size = bounds.size, shift = shifts[key]
      var node = node; node.shift = shift; nodes[key] = node
      layer.removeAllAnimations()
      let start: Double, duration: Double
      let frame: (Double) -> (CGPoint, Float)
      var special: SpecialBullet?
      switch key {
      case .regular(let i):
        let p = scene.plan.rows[i]; start = p.bullet.time; duration = p.duration
        frame = { t in
          (BulletTrackFrame.rect(mode: p.mode, lane: p.lane, width: p.width, point: scene.point,
            step: scene.point * scene.style.lineHeight, elapsed: t, duration: p.duration, size: size)?.origin ?? .zero, 1)
        }
      case .special(let i):
        let b = scene.plan.special[i], sp = b.special!
        special = sp; start = b.time; duration = sp.duration
        frame = { t in let f = sp.frame(t); return (CGPoint(x: f.x * size.width, y: f.y * size.height), Float(f.opacity)) }
      }
      if let shift, shift.resume == nil {
        let f = frame(min(duration, max(0, shift.sample - start)))
        layer.position = f.0; layer.opacity = f.1; return
      }
      let offset = shift.map { ($0.resume ?? $0.sample) - $0.sample } ?? 0
      let first = frame(0), last = frame(duration)
      layer.position = first.0; layer.opacity = 0
      let alpha = CABasicAnimation(keyPath: "opacity")
      alpha.fromValue = first.1; alpha.toValue = last.1; alpha.duration = duration
      var animations: [CAAnimation] = [alpha]
      if first.0 != last.0 {
        if let sp = special {
          // Sample only the moving part, so a short motion with a long hold keeps its timing.
          var times = [0.0]
          if sp.delay > 0 && sp.delay < duration { times.append(sp.delay) }
          let end = min(duration, sp.delay + sp.movement)
          if end > sp.delay {
            for n in 1...20 { times.append(sp.delay + (end - sp.delay) * Double(n) / 20) }
          } else if sp.delay < duration {
            times.append(min(duration, sp.delay + 0.00001))
          }
          if times.last! < duration { times.append(duration) }
          let motion = CAKeyframeAnimation(keyPath: "position")
          motion.keyTimes = times.map { NSNumber(value: $0 / duration) }
          motion.values = times.map { NSValue(cgPoint: frame($0).0) }
          motion.duration = duration; animations.append(motion)
        } else {
          let motion = CABasicAnimation(keyPath: "position")
          motion.fromValue = NSValue(cgPoint: first.0); motion.toValue = NSValue(cgPoint: last.0)
          motion.duration = duration; animations.append(motion)
        }
      }
      let group = CAAnimationGroup()
      group.animations = animations; group.duration = duration
      group.beginTime = max(AVCoreAnimationBeginTimeAtZero, start + offset)
      group.isRemovedOnCompletion = false; group.timingFunction = CAMediaTimingFunction(name: .linear)
      if fps > 0, let screen = window?.windowScene?.screen {
        let hz = Float(min(fps, screen.maximumFramesPerSecond))
        group.preferredFrameRateRange = .init(minimum: min(30, hz), maximum: hz, preferred: hz)
      }
      layer.add(group, forKey: "bullet")
    }
  }
}
