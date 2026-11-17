import SwiftUI

@main struct PiliNativeApp: App {
  init() {
    _ = MediaNetwork.shared
  }
  @AppStorage(TypefaceChoice.key) private var faceData = Data()
  @State private var restoredFaceData: Data?
  @UIApplicationDelegateAdaptor(DownloadLifecycle.self) private var appDelegate
  @StateObject private var accounts = AccountContext()
  @StateObject private var indicators = UnreadIndicators()
  @AppStorage(VipExperience.autoKey) private var autoVipExperience = true
  @AppStorage(HighRefreshRate.key) private var force120 = false
  @AppStorage("badge.dynamicMode") private var dynBadge = 2
  @AppStorage("badge.messageMode") private var msgBadge = 2
  @AppStorage("badge.messageMask") private var mask = UnreadTotals.allMask
  @AppStorage("inbox.hideLikes") private var hideLikeNotices = false
  private var visibleMask: Int { UnreadTotals.visibleMask(mask,hideLikes:hideLikeNotices) }
  @AppStorage("badge.periodic") private var periodic = true
  @AppStorage("badge.minutes") private var minutes = 5
  @State private var badgeRevision = 0
  private let sleepTimer = PlaybackSleepTimer.shared
  @Environment(\.scenePhase) private var phase
  @AppStorage(NavigationLayout.key) private var layoutData = Data()
  @State private var active = NavigationLayout.current().launch
  @State private var incoming: IncomingRoute?
  @State private var homeRevision = 0
  private func returnHome(_ layout: NavigationLayout) {
    incoming = nil
    active = layout.tabs.contains(.home) ? .home : layout.launch
    homeRevision &+= 1
  }
  @AppStorage("appearance") private var appearance = "system"
  private func badge(_ tab: MainTab) -> Text? {
    let m = tab == .mine
    if !m && tab != .dynamics { return nil }
    return UnreadTotals.label(
      indicators.count(for: accounts.state.active, messages: m), mode: m ? msgBadge : dynBadge
    ).map { Text(verbatim: $0) }
  }
  var body: some Scene {
    WindowGroup {
      let layout = NavigationLayout.read(layoutData)
      let typeface = restoredFaceData == faceData ? TypefaceChoice.decode(faceData) : .standard
      MainNavShell(layout: layout, badge: badge, active: $active).id(homeRevision)
        .onReceive(NotificationCenter.default.publisher(for: AppLinkPage.returnHome)) { _ in returnHome(layout) }
        .onChange(of: layout) { _, new in if !new.tabs.contains(active) { active = new.launch } }
        .id(
          accounts.state.active
        )
        .piliToastHost()
        .onReceive(NotificationCenter.default.publisher(for: .piliUnreadChanged)) { _ in
          badgeRevision += 1
        }
        .task(id: "\(accounts.state.active ?? ""):\(phase == .active):\(autoVipExperience)") {
          if phase == .active, autoVipExperience {
            await VipExperienceCoordinator.shared.run(account: accounts.state.active)
          }
        }
        .task(
          id: [
            accounts.state.active ?? "", String(phase == .active), active.rawValue,
            String(layout.tabs.contains(.dynamics)), String(visibleMask), String(dynBadge),
            String(msgBadge),
            String(periodic), String(minutes), String(badgeRevision),
          ].joined(separator: ":")
        ) {
          await indicators.track(
            uid: accounts.state.active, active: phase == .active,
            showMessages: msgBadge != 0 && visibleMask != 0,
            showDynamics: dynBadge != 0 && layout.tabs.contains(.dynamics) && active != .dynamics,
            mask: visibleMask, periodic: periodic, minutes: minutes)
        }.environment(
          \.piliTypeface, typeface
        ).font(typeface.font(.body))
        .onReceive(sleepTimer.$homeRevision.dropFirst().removeDuplicates()) { _ in returnHome(layout) }
        .onChange(of: phase) { _, v in if v == .active { sleepTimer.check() } }
        .onChange(of: "\(force120):\(phase == .active)", initial: true) { _, _ in
          HighRefreshRate.shared.set(force120 && phase == .active)
        }
        .onChange(of: phase) { _, v in
          if v == .background { Task { try? await DiagnosticJournal.shared.flush() } }
        }
        .modifier(SleepExitStatus())
        .modifier(NightCanvas())
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .modifier(NativeTheme()).modifier(UpdatePrompt())
        .onChange(of: accounts.state.active, initial: true) { previous, uid in
          if previous != uid { sleepTimer.cancel() }
          CastState.shared.end()
          ListenQueue.shared.activate(account: uid)
        }
        .onChange(of: accounts.state.owner(.role(.video))) { _, uid in
          CastState.shared.end()
          VideoInterruptionRecovery.shared.clear()
          VideoScenePause.shared.resetAll()
          ListenQueue.shared.videoAccountChanged(to: uid)
        }
        .onOpenURL { url in
          if OfficialAppHandoff.shared.returnedToSender(url){return}
          guard let link = SharedLink.parse(url.absoluteString) else { return }
          if link == .appPage(.root) { returnHome(layout) } else { incoming = IncomingRoute(link: link) }
        }
        .piliSheet(item: $incoming) { r in
          PiliNavigationStack {
            LinkDestination(item: r.link).toolbar {
              ToolbarItem(placement: .cancellationAction) { Button("关闭") { incoming = nil } }
            }
          }
        }
        .modifier(NativeInterfaceScale())
        .task {
          NativeMetricSubscriber.start()
          await accounts.refresh()
        }
        .task(id: faceData) {
          let bytes = faceData
          await Task.detached(priority: .userInitiated) {
            CustomTypefaces.restore(TypefaceChoice.decode(bytes))
          }.value
          if !Task.isCancelled { restoredFaceData = bytes }
        }
        // Include destinations presented by the app itself, in particular incoming video links.
        .environmentObject(accounts).environmentObject(indicators)
    }
  }
}
