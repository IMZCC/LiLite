import AVFoundation
import Combine
import SwiftUI
import UIKit

struct BulletScene {
  let id = UUID()
  let plan: BulletLayoutPlan, style: DanmakuStyle, point: CGFloat, scale: CGFloat
  /// Everything but the bullets themselves that shaped the plan (size, area, filters). Scenes that
  /// share it differ only by bullets added or recalled, so the surface keeps what is on screen.
  var rules = 0
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
    private var shifts = [Row: Shift](), lastNow = -Double.infinity
    /// Layers a new plan placed differently, left to finish their flight.
    private var orphans = [(layer: CALayer, until: Double)]()
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
      if changed {
        if let old = scene, let next, fps == frequency, old.rules == next.rules, old.style == next.style,
          old.point == next.point, old.scale == next.scale
        {
          carry(from: old, to: next)
        } else {
          clearRows()
        }
        scene = next; fps = frequency
      }
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
        [weak self] _ in MainActor.assumeIsolated { self?.lastNow = -.infinity; self?.refresh() }
      }
      refresh()
    }
    private func clearRows() {
      ticket = UUID(); worker?.cancel(); worker = nil
      nodes.values.forEach { $0.layer.removeFromSuperlayer() }
      nodes.removeAll(); wanted.removeAll(); failed.removeAll(); shifts.removeAll()
      dropOrphans(before: .infinity)
    }
    private func dropOrphans(before time: Double) {
      guard !orphans.isEmpty else { return }
      CATransaction.begin(); CATransaction.setDisableActions(true)
      orphans.removeAll { orphan in
        guard orphan.until <= time else { return false }
        orphan.layer.removeFromSuperlayer(); return true
      }
      CATransaction.commit()
    }
    /// A new plan for the same picture (the next 6-minute segment, a posted or recalled comment)
    /// keeps the layers of bullets it places the same way, instead of blanking every bullet on
    /// screen and drawing them again.
    private func carry(from old: BulletScene, to next: BulletScene) {
      ticket = UUID(); worker?.cancel(); worker = nil
      var moved = [Row: Node]()
      let now = player?.currentTime().seconds ?? 0
      CATransaction.begin(); CATransaction.setDisableActions(true)
      for (key, node) in nodes {
        guard let target = Self.match(key, from: old.plan, in: next.plan) else {
          // Placed elsewhere now: a bullet in flight finishes on its old lane rather than vanish
          // (its new placement is not admitted mid-flight); one yet to start takes the new one.
          let start: Double, end: Double
          switch key {
          case .regular(let i): start = old.plan.rows[i].bullet.time; end = start + old.plan.rows[i].duration
          case .special(let i):
            start = old.plan.special[i].time; end = start + (old.plan.special[i].special?.duration ?? 0)
          }
          if now.isFinite, start < now - 0.35, end > now { orphans.append((node.layer, end)) }
          else { node.layer.removeFromSuperlayer() }
          continue
        }
        switch target {
        case .regular(let i): node.layer.zPosition = CGFloat(i + 1)
        case .special(let i): node.layer.zPosition = CGFloat(i) - CGFloat(next.plan.special.count)
        }
        moved[target] = node
      }
      CATransaction.commit()
      nodes = moved
      wanted = Set(wanted.compactMap { Self.match($0, from: old.plan, in: next.plan) })
      failed.removeAll(); shifts.removeAll()
    }
    private static func match(_ key: Row, from old: BulletLayoutPlan, in next: BulletLayoutPlan) -> Row? {
      switch key {
      case .regular(let i):
        guard old.rows.indices.contains(i) else { return nil }
        let p = old.rows[i]
        guard let j = locate(p.bullet, in: next.rows, { $0.bullet }) else { return nil }
        let q = next.rows[j]
        guard q.mode == p.mode, q.lane == p.lane, q.width == p.width, q.duration == p.duration,
          q.repeats == p.repeats, q.mine == p.mine
        else { return nil }
        return .regular(j)
      case .special(let i):
        guard old.special.indices.contains(i) else { return nil }
        return locate(old.special[i], in: next.special, { $0 }).map(Row.special)
      }
    }
    private static func locate<T>(_ target: Bullet, in entries: [T], _ bullet: (T) -> Bullet) -> Int? {
      var lo = 0, hi = entries.count
      while lo < hi {
        let m = lo + (hi - lo) / 2
        if bullet(entries[m]).time < target.time { lo = m + 1 } else { hi = m }
      }
      while lo < entries.count, bullet(entries[lo]).time == target.time {
        if bullet(entries[lo]) == target { return lo }
        lo += 1
      }
      return nil
    }
    /// Past the cap, rows already on screen keep their place and new ones wait (or are skipped once
    /// they would only pop in mid-flight). Picking the newest rows on every tick instead dropped
    /// older bullets mid-screen and brought them back as shorter ones ended: dense episodes flickered.
    private func admit(_ candidates: [Row], cap: Int, now: Double, fresh: Bool, start: (Row) -> Double) -> [Row] {
      guard candidates.count > cap else { return candidates }
      if fresh {
        let active = candidates.filter { start($0) <= now }
        let shown = Array(active.suffix(cap))
        return shown + candidates.filter { start($0) > now }.prefix(cap - shown.count)
      }
      var kept = candidates.filter { wanted.contains($0) }
      for row in candidates where kept.count < cap && !wanted.contains(row) && start(row) >= now - 0.35 {
        kept.append(row)
      }
      return kept
    }
    private func detachItem() {
      if let timer { player?.removeTimeObserver(timer) }; timer = nil
      if let jump { NotificationCenter.default.removeObserver(jump) }; jump = nil
      clearRows(); sync?.removeFromSuperlayer(); sync = nil; boundItem = nil; stateWatch = nil
    }
    func close() {
      detachItem(); itemWatch = nil; picks = nil; inspector = nil; scene = nil; player = nil
    }
    /// mpv's position arrives in steps and is extrapolated in between, so it wobbles by tens of
    /// milliseconds. Re-anchoring the bullets' timebase to it on every tick (four times a second,
    /// and on every state change) moved every bullet on screen by that wobble: dense episodes
    /// shook and flickered. The timebase now runs on its own and is re-anchored only when the
    /// speed changes (play, pause, rate) or it has really drifted from the picture.
    private func syncClock() {
      guard let player, player.engineKind == .mpv, let sync else { return }
      let speed: Float = player.timeControlStatus == .playing ? player.rate : 0
      let target = player.currentTime().seconds
      guard target.isFinite else { return }
      if sync.speed == speed, sync.beginTime != 0 {
        let shown = sync.convertTime(CACurrentMediaTime(), from: nil)
        if abs(shown - target) < Self.clockTolerance { return }
      }
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      sync.speed = speed
      sync.timeOffset = target
      sync.beginTime = CACurrentMediaTime()
      CATransaction.commit()
    }
    /// How far the bullets may run from the player's clock before they are pulled back to it.
    private static let clockTolerance = 0.15
    /// A step back smaller than this is the clock's wobble, not a seek (seeks also post a jump).
    private static let backwardJump = 0.5
    private func refresh() {
      guard let scene, let item = boundItem, item === player?.playbackItem, bounds.width > 0 else { return }
      syncClock()
      let now = player?.currentTime().seconds ?? 0
      guard now.isFinite else { return }
      let plan = scene.plan
      // A jump (seek, scrub, a skipped intro) or an empty screen fills from the newest rows.
      let jumped = now < lastNow - Self.backwardJump || now > lastNow + 2
      lastNow = now
      dropOrphans(before: jumped ? .infinity : now)
      let fresh = jumped || (wanted.isEmpty && orphans.isEmpty)
      let rows = admit(plan.regular(at: now, ahead: 1, limit: 512).map(Row.regular), cap: 96, now: now,
        fresh: fresh) { if case .regular(let i) = $0 { plan.rows[i].bullet.time } else { 0 } }
      let fx = admit(plan.effects(at: now, ahead: 1, limit: 128).map(Row.special), cap: 24, now: now,
        fresh: fresh) { if case .special(let i) = $0 { plan.special[i].time } else { 0 } }
      var order = rows + fx
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
