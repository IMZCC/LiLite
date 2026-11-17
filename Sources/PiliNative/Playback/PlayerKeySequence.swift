import Foundation

enum PlayerKey: Equatable {
  case q, r, w, e, t, v, g, f, d, l, m, s, enter, space, left, right, up, down, previous, next,
    slower, faster, one, two
}
enum PlayerKeyEffect: Equatable {
  case like, triple, armTriple, coin, favorite, later, relation, enter, refresh, fullscreen,
    bullets, lock, mute, capture, toggle, previous, next
  case setSpeed(Double)
  case changeSpeed(Int)
  case volume(Int)
  case previewBack(Int)
  case seekBack(Int)
  case seekForward, boost, restore
}
struct PlayerKeyScope: Equatable {
  let live: Bool, social: Bool, relation: Bool, send: Bool, full: Bool, capture: Bool, step: Bool,
    ready: Bool, canPlay: Bool, locked: Bool
  func supports(_ k: PlayerKey, shift: Bool) -> Bool {
    if locked { return k == .f || (full && k == .l) }
    switch k {
    case .f: return true
    case .q, .r: return live || social
    case .w, .e, .t, .v: return social && !live
    case .g: return social && relation && !live
    case .enter: return send
    case .up, .down, .m: return ready
    case .left, .right, .faster, .slower: return ready && !live
    case .one, .two: return shift && ready && !live
    case .l: return full
    case .s: return full && capture && ready
    case .space: return canPlay
    case .previous, .next: return !live && step
    case .d: return true
    }
  }
}
/// The runner supplies monotonic milliseconds; hardware repeat events never start another write.
struct PlayerKeySequence {
  private(set) var held: PlayerKey?, from = 0, stage = 0
  var delay: Int? {
    guard let held else { return nil }
    switch held {
    case .q, .r: return stage == 0 ? from + 200 : stage == 1 ? from + 1400 : nil
    case .left: return from + 200 * (stage + 1)
    case .right: return stage == 0 ? from + 200 : nil
    case .up, .down: return from + 150 * (stage + 1)
    default: return nil
    }
  }
  mutating func cancel() -> [PlayerKeyEffect] {
    let out: [PlayerKeyEffect] = held == .right && stage > 0 ? [.restore] : []
    held = nil
    stage = 0
    return out
  }
  mutating func down(_ k: PlayerKey, at: Int, scope: PlayerKeyScope, shift: Bool = false)
    -> [PlayerKeyEffect]
  {
    guard held != k else { return [] }
    let prior = cancel()
    guard scope.supports(k, shift: shift) else { return prior }
    switch k {
    case .q, .r: if scope.live { return prior + [.refresh] }
    case .left, .right, .up, .down: break
    case .w: return prior + [.coin]
    case .e: return prior + [.favorite]
    case .t, .v: return prior + [.later]
    case .g: return prior + [.relation]
    case .f: return prior + [.fullscreen]
    case .d: return prior + [.bullets]
    case .m: return prior + [.mute]
    case .s: return prior + [.capture]
    case .l: return prior + [.lock]
    case .enter: return prior + [.enter]
    case .space: return prior + [.toggle]
    case .previous: return prior + [.previous]
    case .next: return prior + [.next]
    case .slower: return prior + [.changeSpeed(-1)]
    case .faster: return prior + [.changeSpeed(1)]
    case .one: return prior + [.setSpeed(1)]
    case .two: return prior + [.setSpeed(2)]
    }
    held = k
    from = at
    stage = 0
    if k == .up || k == .down { return prior + [.volume(k == .up ? 1 : -1)] }
    return prior
  }
  mutating func pulse(_ t: Int, playing: Bool) -> [PlayerKeyEffect] {
    guard let key = held, let next = delay, t >= next else { return [] }
    let elapsed = max(0, t - from)
    switch key {
    case .q, .r:
      if elapsed >= 1400 {
        stage = 2
        return [.triple]
      }
      stage = 1
      return [.armTriple]
    case .left:
      stage = min(10000, elapsed / 200)
      return [.previewBack(stage)]
    case .up, .down:
      stage = min(10000, elapsed / 150)
      return [.volume(key == .up ? 1 : -1)]
    case .right:
      stage = playing ? 1 : 2
      return playing ? [.boost] : []
    default: return []
    }
  }
  mutating func up(_ k: PlayerKey, at: Int, playing: Bool) -> [PlayerKeyEffect] {
    guard held == k else { return [] }
    let tick = pulse(at, playing: playing)
    let prior = stage
    let elapsed = max(0, at - from)
    held = nil
    stage = 0
    switch k {
    case .q, .r: return tick.filter { $0 != .armTriple } + (elapsed < 200 && k == .q ? [.like] : [])
    case .left: return [.seekBack(max(1, prior))]
    case .right: return prior == 1 ? [.restore] : [.seekForward]
    default: return []
    }
  }
}

enum PlayerTouchZone {
  enum Zone { case back, center, forward }
  static func doubleTap(_ x: Double, width: Double) -> Zone {
    guard x.isFinite, width.isFinite, width > 0 else { return .center }
    return x < width / 4 ? .back : x >= width * 0.75 ? .forward : .center
  }
}
