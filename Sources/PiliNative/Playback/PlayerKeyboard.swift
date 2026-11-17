import AVFoundation
import SwiftUI
import UIKit

struct PlayerKeyboard: ViewModifier {
  let player: any PlaybackEngine
  var live = false, locked = false
  var toggle: (() -> Void)? = nil, fullscreen: (() -> Void)? = nil, bullets: (() -> Void)? = nil,
    lock: (() -> Void)? = nil, step: ((Bool) -> Void)? = nil
  var allowCapture = false, full = false, foreground = true
  var model: PlayerModel? = nil, item: EngagementItem? = nil, cid: Int64? = nil,
    creator: Int64? = nil, bvid: String? = nil
  var liveRefresh: (() -> Void)? = nil, liveSend: (() -> Void)? = nil,
    skipOffline: (() -> Bool)? = nil
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.scenePhase) private var scene
  @Environment(\.listenOrigin) private var origin
  @AppStorage("player.keyboard") private var enabled = true
  @AppStorage("player.seekStep") private var seekSeconds = 10.0
  @AppStorage("player.holdSpeed") private var hold = 3.0
  @AppStorage("player.doubleSpeed") private var doubleSpeed = false
  @StateObject private var fence = PlayerKeyFocus()
  @FocusState private var focused: Bool
  @State private var keys = PlayerKeySequence()
  @State private var timer: Task<Void, Never>?
  @State private var pauseHint: Task<Void, Never>?
  @State private var boosted: AnyObject?
  @State private var boostedRate: Float = 0
  @State private var normalRate: Float = 1
  @State private var capture = false
  @State private var composer = false
  @State private var textEditing = false
  @State private var draft = ""
  @State private var issue: String?
  @State private var feedback: String?
  @State private var at = 0.0
  @State private var anchor = 0.0
  @State private var ticket: PlayerKeyTicket?
  @State private var lastItem: ObjectIdentifier?
  @State private var composeItem: AnyObject?
  @State private var composeScope: String?
  @State private var watchWrite = false
  @State private var watchTask: Task<Void, Never>?
  private var uid: String? { accounts.state.active }
  private var scope: String {
    [
      live ? "live" : "vod", item?.key ?? "", String(cid ?? 0), bvid ?? "", uid ?? "",
      accounts.state.owner(.role(.video)) ?? "",
    ].joined(separator: ":")
  }
  private var canReceive: Bool {
    enabled && focused && foreground && !textEditing && scene == .active && !capture && !composer
      && fence.available()
  }
  private var timing: PlayerKeyScope {
    .init(
      live: live, social: item != nil, relation: creator != nil,
      send: liveSend != nil || (cid != nil && !(bvid ?? "").isEmpty) || skipOffline != nil,
      full: full, capture: allowCapture, step: step != nil, ready: player.playbackItem != nil,
      canPlay: toggle != nil || player.playbackItem != nil, locked: locked)
  }
  private static var milliseconds: Int { Int(ProcessInfo.processInfo.systemUptime * 1000) }
  private static func key(_ press: KeyPress) -> PlayerKey? {
    let v = press.key
    if v == .return { return .enter }
    if v == .space { return .space }
    if v == .leftArrow { return .left }
    if v == .rightArrow { return .right }
    if v == .upArrow { return .up }
    if v == .downArrow { return .down }
    switch String(v.character).lowercased() {
    case "q": return .q
    case "r": return .r
    case "w": return .w
    case "e": return .e
    case "t": return .t
    case "v": return .v
    case "g": return .g
    case "f": return .f
    case "l": return .l
    case "m": return .m
    case "s": return .s
    case "d": return .d
    case "[": return .previous
    case "]": return .next
    case ",": return .slower
    case ".": return .faster
    case "1", "!": return .one
    case "2", "@", "\"": return .two
    default: return nil
    }
  }
  private func keypress(_ press: KeyPress) -> KeyPress.Result {
    guard canReceive, press.modifiers.intersection([.command, .control, .option]).isEmpty else {
      cancelHolds()
      return .ignored
    }
    guard let key = Self.key(press) else {
      if press.phase == .down { cancelHolds() }
      return .ignored
    }
    if key == .f && fullscreen == nil { return .ignored }
    if key == .l && lock == nil { return .ignored }
    let shift = press.modifiers.contains(.shift)
    let state = timing
    guard state.supports(key, shift: shift) || keys.held == key else {
      if press.phase == .down { cancelHolds() }
      return .ignored
    }
    if press.phase == .repeat { return .handled }
    if press.phase == .down {
      if key == .left {
        let t = player.currentTime().seconds
        anchor = t.isFinite ? t : 0
      }
      let effects = keys.down(key, at: Self.milliseconds, scope: state, shift: shift)
      run(effects)
      schedule()
    } else if press.phase == .up {
      let effects = keys.up(key, at: Self.milliseconds, playing: player.rate != 0)
      run(effects)
      schedule()
      if keys.held == nil, [.q, .r, .left, .right].contains(key) { feedback = nil }
    }
    return .handled
  }
  private func schedule() {
    timer?.cancel()
    timer = nil
    guard let when = keys.delay, let key = keys.held else { return }
    let id = scope
    let program = player.playbackItem
    timer = Task { @MainActor in
      do { try await Task.sleep(for: .milliseconds(max(1, when - Self.milliseconds))) } catch {
        return
      }
      guard canReceive, id == scope, program === player.playbackItem, keys.held == key else {
        cancelHolds()
        return
      }
      let effects = keys.pulse(Self.milliseconds, playing: player.rate != 0)
      run(effects)
      schedule()
    }
  }
  private func restore() {
    if let boosted, boosted === player.playbackItem, player.rate != 0,
      abs(player.rate - boostedRate) < 0.001
    {
      player.rate = normalRate
    }
    boosted = nil
  }
  private func cancelHolds() {
    timer?.cancel()
    timer = nil
    _ = keys.cancel()
    restore()
    feedback = nil
  }
  private func reset() {
    cancelHolds()
    watchTask?.cancel()
    watchTask = nil
    watchWrite = false
    ticket = nil
    composeItem = nil
    composeScope = nil
    capture = false
    composer = false
    draft = ""
    issue = nil
  }
  private func move(to value: Double) {
    guard let i = player.playbackItem, value.isFinite else { return }
    let t = player.currentTime().seconds
    let d = player.playbackDuration
    guard t.isFinite, d.isFinite, d > 0 else { return }
    let goal = min(d, max(0, value))
    if let model {
      Task { await model.seekThenPlay(goal, item: i) }
    } else {
      if let native = player.nativePlayer { OfflineDecoderItem.aboutToSeek(native, to: goal) }
      Task { @MainActor in
        if await player.seek(
          to: .init(seconds: goal, preferredTimescale: 600), toleranceBefore: .zero,
          toleranceAfter: .zero), i === player.playbackItem
        {
          player.playImmediately(atRate: player.defaultRate)
        }
      }
    }
  }
  private func speed(_ v: Double) {
    guard !live, v.isFinite, v > 0, boosted == nil, let i = player.playbackItem else { return }
    let moving = player.rate != 0
    if let model {
      model.rate = Float(v)
    } else {
      player.defaultRate = Float(v)
      if let native = player.nativePlayer, let item = i as? AVPlayerItem { VideoTransport.prepare(native, item) }
    }
    if moving { player.rate = Float(v) }
    hint("\(v.formatted())×")
  }
  private func hint(_ text: String) {
    pauseHint?.cancel()
    feedback = text
    pauseHint = Task { @MainActor in
      do { try await Task.sleep(for: .milliseconds(900)) } catch { return }
      feedback = nil
    }
  }
  private func run(_ effects: [PlayerKeyEffect]) {
    for effect in effects {
      switch effect {
      case .toggle:
        if let toggle {
          toggle()
        } else if player.rate != 0 {
          player.pause()
        } else {
          player.play()
        }
      case .fullscreen: fullscreen?()
      case .bullets: bullets?()
      case .lock: lock?()
      case .capture: capture = true
      case .mute: player.isMuted.toggle()
      case .previous: step?(false)
      case .next: step?(true)
      case .refresh: liveRefresh?()
      case .enter:
        if let liveSend {
          liveSend()
          break
        }
        if skipOffline?() == true { break }
        let clock = player.currentTime().seconds
        let now = clock.isFinite ? max(0, clock) : max(0, model?.seconds ?? 0)
        if let model, UserDefaults.standard.bool(forKey: "sponsor.enabled"),
          let s = model.sponsor.last(where: {
            $0.valid && model.sponsorRules.mode($0) == 2 && $0.segment[0] <= now
              && now < $0.segment[1]
          })
        {
          model.skipSponsor(s)
          break
        }
        if let model,UserDefaults.standard.string(forKey:"play.episodeSkip")==EpisodeSkipMode.manual.rawValue,
          let clip=model.clips.first(where:{$0.contains(now)}){model.seek(clip.end);break}
        guard let cid, cid > 0, !(bvid ?? "").isEmpty else { break }
        guard uid != nil else {
          issue = "请先登录"
          break
        }
        if let uid, BulletAvailability.shared.closed(cid, owner: uid) {
          issue = "UP 主已关闭弹幕"
          break
        }
        at = now
        if player.rate != 0, let i = player.playbackItem {
          composeItem = i
          composeScope = scope
          player.pause()
        }
        composer = true
      case .volume(let dir):
        player.presentationVolume = min(1, max(0, player.presentationVolume + Float(dir) * 0.1))
        hint("音量 \(Int((player.presentationVolume*100).rounded()))%")
      case .changeSpeed(let dir):
        let rates = SpeedPresets.current(.standard).sorted()
        let now = Double(player.defaultRate)
        if let value =
          (dir > 0 ? rates.first { $0 > now + 0.001 } : rates.last { $0 < now - 0.001 })
        {
          speed(value)
        }
      case .setSpeed(let v): speed(v)
      case .previewBack(let n): feedback = clockText(max(0, anchor - Double(n) * seekSeconds))
      case .seekBack(let n): move(to: anchor - Double(n) * seekSeconds)
      case .seekForward: move(to: player.currentTime().seconds + seekSeconds)
      case .boost:
        guard player.rate != 0, let i = player.playbackItem else { break }
        normalRate = player.rate
        boosted = i
        boostedRate = doubleSpeed ? player.defaultRate * 2 : Float(hold)
        player.rate = boostedRate
        feedback = "\(boostedRate.formatted())×"
      case .restore: restore()
      case .armTriple:
        TouchFeedback.light()
        feedback = "按住三连"
      case .later: watchLater()
      case .like, .triple, .coin, .favorite, .relation:
        guard let uid else {
          issue = "请先登录"
          break
        }
        if effect == .relation, creator.map(String.init) == uid { break }
        ticket = .init(effect: effect, scope: scope, owner: uid)
      }
    }
  }
  private func watchLater() {
    guard let uid else {
      issue = "请先登录"
      return
    }
    guard let item, let id = item.aid ?? ArchiveNumber.av(item.bvid), !watchWrite else { return }
    let mark = scope
    let marked = PlayerKeyMemory.shared.contains(
      id, owner: uid, origin: origin?.source == 8 && origin?.extra == 2 && origin?.id == Int64(uid))
    watchWrite = true
    watchTask = Task { @MainActor in
      defer { if scope == mark { watchWrite = false } }
      do {
        try Task.checkCancellation()
        let request = try PlaybackSocialRequest.later(item, removing: marked)
        try await BiliAPI.shared.submit(request.path, request.fields, expectedAccount: uid)
        guard !Task.isCancelled, scope == mark else { return }
        PlayerKeyMemory.shared.mark(id, owner: uid, value: !marked)
        hint(marked ? "已移出稍后再看" : "已加入稍后再看")
      } catch { if !Task.isCancelled, scope == mark { issue = error.localizedDescription } }
    }
  }
  private func editing(_ value: Bool) {
    textEditing = value
    if value {
      focused = false
      cancelHolds()
    }
  }
  func body(content: Content) -> some View {
    content.background(PlayerKeyFocusMarker(owner: fence).allowsHitTesting(false)).focusable(
      enabled && foreground
    ).focused($focused).focusEffectDisabled()
      .onKeyPress(phases: [.down, .up, .repeat], action: keypress)
      .overlay(alignment: .bottom) {
        if let feedback {
          Text(feedback).font(.caption.bold()).foregroundStyle(.white).padding(6).background(
            .black.opacity(0.7), in: Capsule()
          ).allowsHitTesting(false)
        }
        if let ticket, ticket.scope == scope, ticket.owner == uid {
          if ticket.effect == .relation, let creator {
            CreatorQuickRelation(mid: creator, keyboard: ticket)
          } else if let item {
            EngagementBar(item: item, keyboard: ticket)
          }
        }
      }
      .onAppear { if enabled && foreground { focused = true } }
      .onChange(of: enabled) { _, on in
        if !on { reset() }
        focused = on && foreground && !textEditing
      }
      .onChange(of: foreground) { _, v in
        if !v { reset() }
        focused = v && enabled && !textEditing
      }
      .onChange(of: scene) { _, p in if p != .active { cancelHolds() } }
      .onChange(of: focused) { _, v in if !v { cancelHolds() } }
      .onChange(of: locked) { _, _ in cancelHolds() }
      .onChange(of: scope) { _, _ in reset() }
      .onReceive(player.itemPublisher) { i in
        let next = i.map(ObjectIdentifier.init)
        if lastItem != next {
          cancelHolds()
          lastItem = next
        }
      }
      .onReceive(
        NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)
      ) { _ in editing(true) }
      .onReceive(
        NotificationCenter.default.publisher(for: UITextView.textDidBeginEditingNotification)
      ) { _ in editing(true) }
      .onReceive(
        NotificationCenter.default.publisher(for: UITextField.textDidEndEditingNotification)
      ) { _ in editing(false) }
      .onReceive(
        NotificationCenter.default.publisher(for: UITextView.textDidEndEditingNotification)
      ) { _ in editing(false) }
      .simultaneousGesture(
        TapGesture().onEnded { if enabled && foreground && !textEditing { focused = true } }
      )
      .piliSheet(isPresented: $capture) {
        CapturePanel(player, automatic: true).presentationDetents([.medium, .large])
      }
      .piliSheet(
        isPresented: $composer,
        onDismiss: {
          let prior = composeItem
          composeItem = nil
          defer { composeScope = nil }
          if let prior, composeScope == scope, prior === player.playbackItem, scene == .active,
            player.rate == 0
          {
            player.playImmediately(atRate: player.defaultRate)
          }
        }
      ) {
        if let uid, let cid, let bvid {
          BulletComposer(
            cid: cid, bvid: bvid, time: at, uid: uid, posted: { model?.didPost($0, cid: cid) },
            draft: $draft)
        }
      }
      .alert("播放快捷键", isPresented: .init(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
        Button("好") {}
      } message: {
        Text(issue ?? "")
      }
      .onDisappear {
        reset()
        pauseHint?.cancel()
      }
  }
}
