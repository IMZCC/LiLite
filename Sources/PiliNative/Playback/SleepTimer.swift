import AVFoundation
import SwiftUI

@MainActor final class PlaybackSleepTimer: ObservableObject {
  static let shared = PlaybackSleepTimer()
  @Published private(set) var state = SleepDeadline.off
  @Published private(set) var homeRevision = 0
  private var wake: Task<Void, Never>?
  private var end: NSObjectProtocol?
  private weak var player: (any PlaybackEngine)?
  private var isLive = false
  // An item can be ready while somebody else is listening. It acquires the timer on playback.
  private final class OfferedVideo {
    weak var item: AnyObject?
    let onSleep: () -> Void
    init(_ item: AnyObject, _ onSleep: @escaping () -> Void) {
      self.item = item
      self.onSleep = onSleep
    }
  }
  private let prepared = NSMapTable<AnyObject, OfferedVideo>.weakToStrongObjects()
  func offerVideo(_ p: any PlaybackEngine, item: AnyObject, autoplay: Bool, onSleep: @escaping () -> Void) {
    prepared.setObject(OfferedVideo(item, onSleep), forKey: p)
    if autoplay || p.rate > 0 { beganVideo(p, item: item) }
  }
  func beganVideo(_ p: any PlaybackEngine, item: AnyObject) {
    guard let offer = prepared.object(forKey: p), offer.item === item else { return }
    prepared.removeObject(forKey: p)
    bind(p, item: item, handlesEnd: true, onSleep: offer.onSleep)
  }
  enum FinishAction: String, CaseIterable { case pause = "暂停播放", home = "返回首页", quit = "退出应用" }
  @Published private(set) var preparingExit = false
  @Published var exitIssue: String?
  private var action = FinishAction.pause, exitToken: UUID?, exitTask: Task<Void, Never>?

  private var pauseAtDeadline:(()->Void)?
  func bindPending(_ p: any PlaybackEngine, live: Bool = false, onSleep: (() -> Void)? = nil) {
    pauseAtDeadline=onSleep
    if let end {
      NotificationCenter.default.removeObserver(end)
      self.end = nil
    }
    if let previous = player, previous !== p {
      VideoScenePause.shared.userIntent(previous)
      previous.pause()
    }
    player = p
    isLive = live
  }
  func bind(_ p: any PlaybackEngine, item: AnyObject, live: Bool = false, handlesEnd: Bool = false, onSleep: (() -> Void)? = nil) {
    bindPending(p, live: live, onSleep: onSleep)
    if !handlesEnd {
      end = NotificationCenter.default.addObserver(
        forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
      ) { [weak self, weak p, weak item] _ in
        Task { @MainActor in
          if let p, let item, self?.player === p, p.playbackItem === item { _ = self?.didFinish(p) }
        }
      }
    }
  }
  func unbind(_ p: any PlaybackEngine) {
    prepared.removeObject(forKey: p)
    guard player === p else { return }
    if let end {
      NotificationCenter.default.removeObserver(end)
      self.end = nil
    }
    player = nil
    pauseAtDeadline=nil
    isLive = false
  }
  func schedule(minutes: Int, afterItem: Bool, action: FinishAction) {
    guard !preparingExit else { return }
    cancel()
    guard (1...1499).contains(minutes) else { return }
    self.action = action
    if action == .quit { exitToken = SleepExitFence.shared.arm() }
    state = .scheduled(Date().addingTimeInterval(Double(minutes) * 60), afterItem: afterItem)
    armWake()
  }
  private func armWake() {
    wake?.cancel()
    guard case .scheduled(let deadline, _) = state else { return }
    let delay = max(0, deadline.timeIntervalSinceNow)
    wake = Task {
      do {
        try await Task.sleep(for: .seconds(delay))
        self.check()
      } catch {}
    }
  }
  func check() {
    let now = Date()
    guard case .scheduled(let deadline, _) = state else { return }
    guard now >= deadline else {
      armWake()
      return
    }
    if state.expire(
      now: now, playing: player?.timeControlStatus != .paused && player != nil, live: isLive)
    {
      act()
    }
  }
  @discardableResult func didFinish(_ p: any PlaybackEngine) -> Bool {
    guard player === p else { return false }
    // Boundary case: the item may finish just as the timer expires, before the wake task runs.
    if case .scheduled(let deadline, _) = state, Date() >= deadline { state = .finishingItem }
    guard state.finish() else { return false }
    act()
    return true
  }
  private func act() {
    wake?.cancel()
    wake = nil
    if let player { VideoInterruptionRecovery.shared.clear(player) }
    VideoScenePause.shared.userIntent(player)
    player?.pause()
    pauseAtDeadline?()
    switch action {
    case .pause: break
    case .home: homeRevision &+= 1
    case .quit:
      if let token = exitToken, exitTask == nil {
        preparingExit = true
        exitTask = Task { await prepareQuit(token) }
      }
    }
  }
  private func prepareQuit(_ token: UUID) async {
    let fence = SleepExitFence.shared
    let background = UIApplication.shared.beginBackgroundTask(withName: "Save before sleep timer exit") { [weak self] in
      Task { @MainActor in self?.cancel() }
    }
    defer {
      if background != .invalid { UIApplication.shared.endBackgroundTask(background) }
      exitTask = nil
    }
    do {
      try Task.checkCancellation()
      NotificationCenter.default.post(name: SleepAppExit.checkpoint, object: nil)
      VideoInterruptionRecovery.shared.clear()
      VideoScenePause.shared.resetAll()
      ListenQueue.shared.stop()
      await CloudWatchProgress.flushPending()
      try Task.checkCancellation()
      try await Downloads.shared.checkpointForExit()
      guard UserDefaults.standard.synchronize() else { throw ServiceError("保存播放设置失败") }
      while fence.current(token) {
        try Task.checkCancellation()
        if fence.finish(token, perform: {
          SystemMediaControls.clearForExit()
          try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
          SleepAppExit.closeScenes(authorized: { fence.committed(token) }) { [weak self] error in
            Task { @MainActor in
              if fence.committed(token) { self?.exitIssue = error }
              await self?.finishedQuit(token)
            }
          }
        }) { return }
        try await Task.sleep(for: .milliseconds(150))
      }
    } catch {
      if !Task.isCancelled { exitIssue = error.localizedDescription }
    }
    await finishedQuit(token)
  }
  private func finishedQuit(_ token: UUID) async {
    guard exitToken == token else { return }
    SleepExitFence.shared.cancel(token)
    await Downloads.shared.releaseExitCheckpoint()
    exitToken = nil
    preparingExit = false
    action = .pause
  }
  func cancel() {
    wake?.cancel()
    wake = nil
    state = .off
    if let token = exitToken {
      SleepExitFence.shared.cancel(token)
      if preparingExit {
        if let task = exitTask { task.cancel() }
        else { Task { await finishedQuit(token) } }
      } else { exitToken = nil }
    }
    action = .pause
  }
}

struct SleepTimerButton: View {
  var live = false
  @State private var open = false
  var body: some View {
    Button {
      open = true
    } label: {
      Label("定时停止", systemImage: "moon.zzz")
    }.piliSheet(isPresented: $open) {
      PiliNavigationStack { SleepTimerForm(live: live) }.presentationDetents([.medium, .large])
    }
  }
}
/// The original's 定时关闭 panel: 禁用 / 15 / 30 / 45 / 60 (and the last custom length) with a
/// check on the running one — a tap starts it and closes — then 自定义 (hour/minute wheels),
/// 额外等待视频播放完毕, and the action chips; the countdown sits at the title's right.
struct SleepTimerForm: View {
  let live: Bool
  @ObservedObject private var timer = PlaybackSleepTimer.shared
  @AppStorage("sleep.lastMinutes") private var chosen = 0
  @AppStorage("sleep.waitItem") private var wait = false
  @AppStorage("sleep.action") private var actionRaw = PlaybackSleepTimer.FinishAction.pause.rawValue
  @State private var custom = false
  @State private var hour = 0
  @State private var minute = 30
  @Environment(\.dismiss) private var systemDismiss
  @Environment(\.roomPanelClose) private var panelClose
  /// In the live room's panel, closing closes the panel (dismiss would leave the room).
  private func dismiss() { if let panelClose { panelClose(()) } else { systemDismiss() } }
  private var action: PlaybackSleepTimer.FinishAction {
    PlaybackSleepTimer.FinishAction(rawValue: actionRaw) ?? .pause
  }
  private var running: Bool { timer.state != .off }
  private static func label(_ m: Int) -> String {
    if m == 0 { return "禁用" }
    if m == 60 { return "60分钟" }
    let h = m / 60, r = m % 60
    return h > 0 && r > 0 ? "\(h)小时\(r)分钟" : h > 0 ? "\(h)小时" : "\(r)分钟"
  }
  var body: some View {
    List {
      Section {
        ForEach(Array(Set([0, 15, 30, 45, 60, chosen])).sorted(), id: \.self) { m in
          Button { start(m) } label: {
            HStack {
              Text(Self.label(m)).foregroundStyle(.primary)
              Spacer()
              if (running ? chosen : 0) == m {
                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(.tint)
              }
            }.contentShape(Rectangle())
          }
        }
        Button {
          hour = (chosen > 0 ? chosen : 30) / 60; minute = (chosen > 0 ? chosen : 30) % 60
          custom = true
        } label: {
          HStack { Text("自定义").foregroundStyle(.primary); Spacer() }.contentShape(Rectangle())
        }
        if !live { Toggle("额外等待视频播放完毕", isOn: $wait) }
      }
      Section {
        HStack(spacing: 10) {
          Text("倒计时结束:")
          ForEach(PlaybackSleepTimer.FinishAction.allCases, id: \.self) { a in
            Button {
              guard a != action else { return }
              TouchFeedback.light()
              actionRaw = a.rawValue
            } label: {
              Text(a.rawValue).font(.footnote.weight(a == action ? .semibold : .regular))
                .foregroundStyle(a == action ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(a == action ? Color.accentColor.opacity(0.14) : Color(uiColor: .tertiarySystemFill),
                  in: Capsule())
            }.buttonStyle(.plain)
          }
        }
      }
    }
    .navigationTitle("定时关闭").navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) { countdown }
      if panelClose == nil { ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } } }
    }
    .sheet(isPresented: $custom) {
      NavigationStack {
        HStack(spacing: 0) {
          Picker("时", selection: $hour) { ForEach(0..<25, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }
            .pickerStyle(.wheel)
          Text("时")
          Picker("分", selection: $minute) { ForEach(0..<60, id: \.self) { Text(String(format: "%02d", $0)).tag($0) } }
            .pickerStyle(.wheel)
          Text("分")
        }
        .padding(.horizontal, 20)
        .navigationTitle("自定义").navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("取消") { custom = false } }
          ToolbarItem(placement: .confirmationAction) {
            Button("确认") { custom = false; start(hour * 60 + minute) }
          }
        }
      }
      .presentationDetents([.height(300)])
    }
  }
  @ViewBuilder private var countdown: some View {
    switch timer.state {
    case .off: EmptyView()
    case .scheduled(let end, _): Text(end, style: .timer).monospacedDigit().font(.subheadline).foregroundStyle(.secondary)
    case .finishingItem: Text("本集结束").font(.subheadline).foregroundStyle(.secondary)
    }
  }
  private func start(_ m: Int) {
    TouchFeedback.light()
    if m <= 0 {
      timer.cancel()
    } else {
      chosen = m
      timer.schedule(minutes: m, afterItem: !live && wait, action: action)
    }
    dismiss()
  }
}

struct SleepExitStatus: ViewModifier {
  @ObservedObject private var sleepTimer = PlaybackSleepTimer.shared
  func body(content: Content) -> some View {
    content
        .safeAreaInset(edge: .top) {
          if sleepTimer.preparingExit {
            HStack {
              ProgressView()
              Text("正在保存，稍后退出")
              Spacer()
              Button("取消") { sleepTimer.cancel() }
            }.padding().background(.regularMaterial)
          }
        }
        .alert("未能定时退出", isPresented: Binding(get: { sleepTimer.exitIssue != nil },
          set: { if !$0 { sleepTimer.exitIssue = nil } })) {
          Button("好") { sleepTimer.exitIssue = nil }
        } message: { Text(sleepTimer.exitIssue ?? "") }
  }
}
