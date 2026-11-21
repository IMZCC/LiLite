import AVKit
import SwiftUI

struct LiveDirectory: View {
  let area: Int?
  let child: String?
  var title = "直播"
  var embedded = false
  @Environment(\.colorScheme) private var colorScheme
  @State private var room = ""
  @AppStorage("live.directoryMobile") private var mobile = false
  @State private var firstFrame = false
  @State private var followed: [LiveRoom] = []
  @State private var areas: [LiveFeedCards.Tab] = []
  @State private var tags: [LiveDirectoryPage.Tag] = []
  @State private var sort: String?
  @State private var feedback: LiveRoom?
  @EnvironmentObject private var accounts: AccountContext
  private var owner: String? { accounts.state.owner(.role(.recommend)) }
  private var scope: String {
    "\(area ?? -1):\(child ?? ""):\(mobile):\(sort ?? ""):\(owner ?? "")"
  }
  var body: some View {
    VStack(spacing: 0) {
      if area == nil {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 8) {
            HStack(spacing: 8) {
              Image(systemName: "number").font(.subheadline.weight(.medium)).foregroundStyle(.secondary)
              TextField("输入直播间号", text: $room).keyboardType(.numberPad)
              if let id = Int64(room), id > 0 {
                LazyLink { LivePlayer(id: id, title: "直播间 \(id)") } label: {
                  Text("进入").font(.subheadline.weight(.semibold))
                }
                .piliGlassButton(prominent: true).controlSize(.small)
                .transition(.scale.combined(with: .opacity))
              }
            }
            .padding(.leading, 14).padding(.trailing, 5).frame(height: 42)
            .piliGlass(in: Capsule())
            .animation(.snappy(duration: 0.2), value: Int64(room) ?? 0 > 0)
            NavigationLink { DeferredPage { LiveSearchView() } } label: {
              Image(systemName: "magnifyingglass").font(.body.weight(.medium))
                .frame(width: 42, height: 42).contentShape(Circle())
            }
            .buttonStyle(.plain).piliGlass(in: Circle(), interactive: true)
            .accessibilityLabel("直播搜索")
            if embedded {
              // Embedded in the home deck: keep options here, not in the shared toolbar, so
              // swiping between channels never changes the navigation bar.
              Menu { optionItems } label: {
                Image(systemName: "slider.horizontal.3").font(.body.weight(.medium))
                  .frame(width: 42, height: 42).contentShape(Circle())
              }
              .buttonStyle(.plain).piliGlass(in: Circle(), interactive: true)
              .accessibilityLabel("直播列表选项")
            }
          }
          HStack(spacing: 8) {
            NavigationLink { DeferredPage { LiveAreaCatalog() } } label: {
              Label("分区", systemImage: "square.grid.2x2").font(.subheadline)
            }.piliGlassButton()
            NavigationLink { DeferredPage { LiveFollows() } } label: {
              Label("关注", systemImage: "heart").font(.subheadline)
            }.piliGlassButton()
            NavigationLink {
              SitePage(url: URL(string: colorScheme == .dark ? "https://www.bilibili.com/h5/match/data/home?navhide=1&native.theme=2&night=1" : "https://www.bilibili.com/h5/match/data/home?navhide=1&native.theme=1&night=0")!)
            } label: {
              Label("赛事", systemImage: "gamecontroller").font(.subheadline)
            }.piliGlassButton()
          }
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
      }
      if mobile && area == nil && (!followed.isEmpty || !areas.isEmpty) {
        ScrollView(.horizontal) {
          HStack(spacing: 8) {
            ForEach(followed) { r in
              LazyLink { LivePlayer(id: r.id, title: r.title) } label: {
                HStack(spacing: 6) {
                  Circle().fill(.red).frame(width: 6, height: 6)
                  Text(r.uname ?? r.title).lineLimit(1)
                }
                .font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7)
                .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
              }
            }
            ForEach(areas, id: \.self) { tab in
              if let parent = tab.area_v2_parent_id, let sub = tab.area_v2_id, let label = tab.title
              {
                NavigationLink {
                  LiveAreaChannels(parent: parent, initial: String(sub), title: label, initialTitle: label)
                } label: {
                  Text(label).font(.subheadline).padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
                }
              }
            }
          }.buttonStyle(.plain).padding(.horizontal, 16)
        }.scrollIndicators(.hidden).scrollClipDisabled().padding(.bottom, 4)
      }
      PageList(empty: "暂无直播", grid: true) { p in
        let page = Int(p ?? "1") ?? 1
        let snapshot = scope
        if mobile {
          let data = try await BiliAPI.shared.mobileLiveRooms(
            page: page, owner: owner, area: area, child: child, sort: sort)
          try Task.checkCancellation()
          if page == 1 && snapshot == scope {
            followed = data.followed
            areas = data.areas
            tags = data.tags
          }
          return data.page
        }
        return try await BiliAPI.shared.rooms(area: area, child: child, page: page)
      } row: { r in
        LiveDirectoryCard(room: r, firstFrame: firstFrame, mobile: mobile) { feedback = r }
      }.id(scope)
    }.piliCatalogTitle(title, embedded: embedded).toolbar {
      if !embedded {Menu {
        optionItems
      } label: {
        Image(systemName: "slider.horizontal.3").accessibilityLabel("直播列表选项")
      }}
    }
    .onChange(of: "\(mobile):\(owner ?? ""):\(area ?? -1):\(child ?? "")") { _, _ in
      feedback = nil
      areas = []
      followed = []
      tags = []
      sort = nil
    }
    .piliSheet(item: $feedback) { r in LiveFeedbackSheet(room: r) }
  }
  @ViewBuilder private var optionItems: some View {
        Picker("直播来源", selection: $mobile) {
          Text("网页推荐").tag(false)
          Text("移动端推荐").tag(true)
        }
        Toggle("显示直播首帧", isOn: $firstFrame)
        if mobile && area != nil && !tags.isEmpty {
          Picker("排序", selection: $sort) {
            Text("默认").tag(String?.none)
            ForEach(tags, id: \.self) { tag in
              if let name = tag.name, let value = tag.sort_type { Text(name).tag(Optional(value)) }
            }
          }
        }
  }
}
struct LivePlayer: View {
  let id: Int64, title: String
  @StateObject private var chat = LiveChat()
  @StateObject private var liveTrack = LiveOverlayTimeline()
  @StateObject private var liveInspector = BulletInspector()
  @AppStorage("dm.tap") private var inspectLive = true
  @State private var readingOlder = false
  @State private var systemFullscreen = false
  @StateObject private var upscale = UpscaleSession()
  @StateObject private var transport = NativeLivePlayback()
  private var player: AVPlayer? { transport.player }
  @State private var error: String?
  @State private var qn: Int? = nil
  private var options: [Int] { transport.selected?.choices ?? [] }
  private var current: Int {
    guard let row = transport.selected, row.endpoints.indices.contains(transport.line) else {
      return 0
    }
    return row.endpoints[transport.line].quality
  }
  @State private var reload = 0
  @State private var chatReload = 0
  @State private var identity: LiveRoomIdentity?
  @State private var liveCard: IMShareCard?
  @State private var header: LiveRoomHeader?
  @State private var headerRevision = 0
  @State private var headerUnavailable = false
  private var roomTitle: String { chat.roomTitle ?? header?.room_info?.title ?? title }
  private var headerOwner: String? { accounts.state.owner(.role(.heartbeat)) }
  @State private var resolvingError: String?
  @State private var resolveAttempt = 0
  @State private var visitAttempts = Set<String>()
  @AppStorage("history.sync") private var recordVisits = true
  @State private var ranks = false
  @EnvironmentObject var accounts: AccountContext
  @State private var shield: LiveShield?
  @State private var keyboardChat=false
  @State private var editShield = false
  @State private var paidSettings = false
  @State private var showPaid = false
  @State private var selectedMessage: LiveActionSelection?
  @State private var replyTo: LiveReplyTarget?
  @State private var enlarged = false
  @State private var locked = false
  @State private var startedRoom: Int64?
  @AppStorage("theater.autoEnter") private var autoEnter = false
  @AppStorage("theater.orientation") private var orientationPref: Int?
  @State private var entryOrientation = TheaterOrientation.defaultMode
  private var orientation: Int { orientationPref ?? entryOrientation }
  @AppStorage("theater.lockButton") private var allowLock = true
  @AppStorage("theater.captureButton") private var allowCapture = true
  private func expand() { guard !locked else{return};enlarged.toggle();chat.presentation(enlarged) }
  @State private var audioOnly = false
  @State private var sleepTimer = false
  /// The stream's picture size, to lay a portrait stream out over the whole page.
  @State private var streamSize = CGSize.zero
  @Environment(\.colorScheme) private var colorScheme
  @State private var expandedChat = false
  /// The season an official match room carries, for its 赛程 · 回放 · 选手评分 tabs.
  @State private var matchStore: LiveMatchStore?
  /// 0 is 互动; the match tabs follow.
  @State private var roomTab = 0
  /// Whether the fullscreen player shows its controls (the room's row follows them).
  @State private var fullscreenControls = true
  @Environment(\.dismiss) private var dismiss
  @State private var panelToken = UUID()
  @State private var showFacts = false
  @State private var liveStarted: Int64?
  @AppStorage("live.paidMode") private var paidMode = 0
  @AppStorage("live.paidFullscreen") private var paidFullscreen = true
  @StateObject private var preferences = PlayerSessionPreferences()
  private var showChat: Bool {
    get { preferences.liveBullets }
    nonmutating set { preferences.liveBullets = newValue }
  }
  private var visible: [LiveLine] {
    chat.lines.filter { shield?.hides($0) != true }
  }
  @ViewBuilder private var theater: some View {
    if let player {
      ViewportAspect(expanded: enlarged) {
        Theater(
          player: player,
          overlay: AnyView(
            ZStack {
              if showChat {
                LiveTrackView(
                  chat: chat, timeline: liveTrack, player: player, shield: shield,
                  inspector: inspectLive ? liveInspector : nil,
                  fullscreen: enlarged || systemFullscreen)
              }
              SuperChatOverlay(
                chat: chat, enabled: showChat && paidFullscreen && paidMode != 2, shield: shield)
            }),
          live: true, showsControls: !locked,
          onPresentation: { full in
            systemFullscreen = full
            chat.presentation(enlarged || full)
          },
          interaction: locked ? nil : AnyView(LiveTouchSurface(player:player,fullscreen:enlarged,
            inspector:inspectLive && showChat ? liveInspector:nil,expand:expand)),
          fullscreen: enlarged,
          expand: expand, upscale: upscale
        ).allowsHitTesting(!locked)
          .modifier(PlayerKeyboard(player:player,live:true,locked:locked,fullscreen:{if locked{locked=false};expand()},bullets:{showChat.toggle()},
            lock:{if enlarged {locked.toggle()}},allowCapture:!audioOnly,full:enlarged,cid:identity?.room_id,liveRefresh:{reload+=1},liveSend:{keyboardChat=true}))
          .onReceive(player.publisher(for:\.timeControlStatus).removeDuplicates()){ state in
            guard state == .playing, let room=identity?.room_id, startedRoom != room else{return}
            startedRoom=room
            if autoEnter && !systemFullscreen && !enlarged {expand()}
          }
          .task(id: ObjectIdentifier(player)) {
            // The picture's size is known once the first frames decode; a portrait stream
            // switches the page to its overlay layout.
            while !Task.isCancelled {
              let size = player.currentItem?.presentationSize ?? .zero
              if size != streamSize { streamSize = size }
              do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
          }
      }
    } else if let error = error ?? transport.issue {
      Text(error).padding()
      Button("重新连接") { reload += 1 }.padding(.horizontal)
    } else {
      ProgressView().frame(maxWidth: .infinity, minHeight: 130)
    }
  }
  /// 更多 at the end of the input bar: everything the room page used to lay out as a row of
  /// buttons — bullets and SuperChat, playback (audio only, reconnect, quality, line, sleep timer)
  /// and the room (anchor, ranking, sharing).
  private var moreMenu: some View {
    Menu {
      Section {
        Toggle("显示直播弹幕", isOn: preferences.binding(\.liveBullets))
        if paidMode != 2, identity != nil { Button("醒目留言", systemImage: "star.bubble") { showPaid = true } }
        Button("醒目留言设置", systemImage: "gearshape") { paidSettings = true }
        if identity != nil, accounts.state.active != nil {
          Button("管理屏蔽规则", systemImage: "eye.slash") { editShield = true }
        }
      }
      Section {
        if !options.isEmpty {
          Menu("画质 · \(qualityName(current))") {
            ForEach(options, id: \.self) { n in Button(qualityName(n)) { qn = n } }
          }
        }
        if !transport.variants.isEmpty { Menu("直播线路") { lineItems } }
        Toggle("仅播放音频", isOn: $audioOnly)
        Button("重新连接", systemImage: "arrow.clockwise") { reload += 1 }
        Button("定时停止", systemImage: "moon.zzz") { sleepTimer = true }
        Button("播放信息", systemImage: "info.circle") { showFacts = true }
        SessionPlaybackSettings(session: preferences)
      }
      if let identity {
        Section {
          NavigationLink { DeferredPage { CreatorSpace(mid: identity.uid, name: liveCard?.author ?? "主播") } } label: {
            Label("主播主页", systemImage: "person.crop.circle")
          }
          Button("贡献榜", systemImage: "list.number") { ranks = true }
          if matchStore != nil {
            Button("赛程、回放与选手评分", systemImage: "trophy") {
              if enlarged { expand() }
              roomTab = 1
            }
          }
          if headerUnavailable { Button("重新读取直播间资料") { headerRevision += 1 } }
          if enlarged { Button("直播聊天", systemImage: "text.bubble") { expandedChat = true } }
          if let url = URL(string: "https://live.bilibili.com/\(identity.room_id)") {
            Button("复制直播间链接", systemImage: "link") { UIPasteboard.general.url = url }
            ShareLink("分享直播间", item: url)
            Link(destination: url) { Label("用浏览器打开", systemImage: "safari") }
          }
          IMShareButton(
            card: liveCard
              ?? .init(
                .live, id: String(identity.room_id), title: title,
                authorID: String(identity.uid))
          )
        }
      }
    } label: {
      Image(systemName: "ellipsis").font(.system(size: 20, weight: .medium))
        .frame(width: 36, height: 36).contentShape(Rectangle())
    }
    .accessibilityLabel("更多")
  }
  @ViewBuilder private var lineItems: some View {
          if let host = transport.currentHost { Text("当前线路：" + host) }
          Section("直播格式") {
            Button("自动选择") { transport.clearPreference() }
            ForEach(transport.variants) { v in
              Button {
                transport.choose(v.id)
              } label: {
                if transport.format == v.id {
                  Label(v.id.label, systemImage: "checkmark")
                } else {
                  Text(v.id.label)
                }
              }
            }
          }
          if transport.audioTracks.count>1 || transport.hasAudioOverride {
            Section("直播音轨") {
              Button("自动选择") {transport.chooseAudio(nil)}
              ForEach(transport.audioTracks) { choice in
                Button {transport.chooseAudio(choice)} label: {
                  if transport.selectedAudio?.id==choice.id {Label(choice.title,systemImage:"checkmark")}
                  else {Text(choice.title)}
                }
              }
            }
          }
          if let v = transport.selected, v.sources.count > 1 {
            Section("播放线路") {
              ForEach(v.sources.indices, id: \.self) { i in
                Button {
                  transport.choose(v.id, i, persist: false)
                } label: {
                  let name = "线路 " + String(i + 1) + " · " + (v.sources[i].host ?? "")
                  if i == transport.line {
                    Label(name, systemImage: "checkmark")
                  } else {
                    Text(name)
                  }
                }
              }
            }
          }
  }
  /// The room's input bar (LiveInputBar): bullets, compose, emotes, like and 更多.
  private var inputBar: some View {
    LiveInputBar(showBullets: preferences.binding(\.liveBullets),
      compose: { keyboardChat = true }, emotes: { keyboardChat = true }) {
      if let identity {
        LiveLikeButton(room: identity, owner: accounts.state.owner(.role(.heartbeat)))
          .id("\(identity.room_id):\(accounts.state.owner(.role(.heartbeat)) ?? "")")
      }
    } more: {
      moreMenu
    }
  }
  /// Back and the room's title over the top of the picture, fading with the player's controls.
  private var playerTopBar: some View {
    HStack(spacing: 2) {
      Button {
        TouchFeedback.light()
        dismiss()
      } label: {
        Image(systemName: "chevron.left").font(.system(size: 19, weight: .medium))
          .frame(width: 44, height: 40).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("返回")
      Text(roomTitle).font(.system(size: 15, weight: .medium)).lineLimit(1)
      Spacer(minLength: 12)
    }
    .foregroundStyle(.white)
    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
    .padding(.trailing, 8)
    .background(LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
      .allowsHitTesting(false))
    .opacity(fullscreenControls ? 1 : 0)
    .animation(.easeOut(duration: 0.2), value: fullscreenControls)
  }
  /// The room's secondary pages, each opened as a panel in the room (`LiveRoomPanelFrame`).
  private enum RoomPanel: Equatable { case actions, ranks, paid, paidSettings, shield, facts, sleep, chat }
  /// The panel on screen: a message's actions over whatever else is open, then the rest.
  private var roomPanel: RoomPanel? {
    if selectedMessage != nil { return .actions }
    if ranks { return .ranks }
    if showPaid { return .paid }
    if paidSettings { return .paidSettings }
    if editShield { return .shield }
    if showFacts { return .facts }
    if sleepTimer { return .sleep }
    if expandedChat { return .chat }
    return nil
  }
  private func closePanel(_ panel: RoomPanel) {
    switch panel {
    case .actions: selectedMessage = nil
    case .ranks: ranks = false
    case .paid: showPaid = false
    case .paidSettings: paidSettings = false
    case .shield: editShield = false
    case .facts: showFacts = false
    case .sleep: sleepTimer = false
    case .chat: expandedChat = false
    }
  }
  @ViewBuilder private func panelContent(_ panel: RoomPanel) -> some View {
    switch panel {
    case .actions: if let selectedMessage { actions(selectedMessage) }
    case .ranks: if let identity { LiveContributionRank(room: identity) }
    case .paid: if let identity { SuperChatFeed(chat: chat, room: identity.room_id, shield: $shield) }
    case .paidSettings: SuperChatSettings()
    case .shield:
      if let identity, let user = accounts.state.active {
        LiveShieldView(room: identity.room_id, user: user, rules: $shield)
      }
    case .facts: LiveProgramInfo(transport: transport, started: liveStarted, audioOnly: audioOnly)
    case .sleep: SleepTimerForm(live: true)
    case .chat: VStack(spacing: 0) { conversation }.navigationTitle("直播聊天")
    }
  }
  private func panelTitle(_ panel: RoomPanel) -> String {
    switch panel {
    case .actions: "留言操作"
    case .ranks: "高能用户"
    case .paid: "醒目留言"
    case .paidSettings: "醒目留言设置"
    case .shield: "弹幕屏蔽"
    case .facts: "播放信息"
    case .sleep: "定时停止"
    case .chat: "直播聊天"
    }
  }
  /// Where a panel goes: under the picture, over the chat column, or a drawer in fullscreen.
  private func panelFrame(w: CGFloat, h: CGFloat, picture: CGSize, wide: Bool, portraitStream: Bool) -> CGRect {
    if enlarged {
      let width = min(420, max(300, w * 0.42))
      return CGRect(x: w - width, y: 0, width: width, height: h)
    }
    if wide { return CGRect(x: picture.width + 0.5, y: 0, width: max(1, w - picture.width - 0.5), height: h) }
    if portraitStream { return CGRect(x: 0, y: h * 0.36, width: w, height: h * 0.64) }
    return CGRect(x: 0, y: picture.height, width: w, height: max(1, h - picture.height))
  }
  @ViewBuilder private func panelLayer(w: CGFloat, h: CGFloat, picture: CGSize, wide: Bool, portraitStream: Bool) -> some View {
    if let panel = roomPanel {
      let rect = panelFrame(w: w, h: h, picture: picture, wide: wide, portraitStream: portraitStream)
      LiveRoomPanelFrame(title: panelTitle(panel), side: enlarged || wide, close: { closePanel(panel) }) {
        panelContent(panel)
      }
      .environment(\.roomPanelClose, StableAction(panelToken) { _ in closePanel(panel) })
      .frame(width: rect.width, height: rect.height)
      .offset(x: rect.minX, y: rect.minY)
      .transition(.move(edge: enlarged || wide ? .trailing : .bottom))
      .id(panel)
    }
  }
  /// The input bar, or while writing, the composer in its place (the keyboard lifts it).
  @ViewBuilder private var bottomBar: some View {
    if keyboardChat, let room = identity?.room_id {
      composerBar(room: room)
    } else {
      inputBar
    }
  }
  private func composerBar(room: Int64) -> some View {
    HStack(spacing: 2) {
      LiveComposer(room: room, reply: $replyTo, focusOnEntry: true)
      Button {
        keyboardChat = false
      } label: {
        Image(systemName: "chevron.down").font(.system(size: 17, weight: .semibold))
          .frame(width: 40, height: 40).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("收起输入框")
    }
    .foregroundStyle(.white)
    .padding(.trailing, 8).padding(.vertical, 6)
    .background(Color(white: 0.1).ignoresSafeArea(edges: .bottom))
    .environment(\.colorScheme, .dark)
  }
  /// Under the anchor: the chat, or in a match room the tabs and whichever page is chosen.
  @ViewBuilder private var roomBody: some View {
    VStack(spacing: 0) {
      if let matchStore {
        LiveRoomTabs(titles: ["互动"] + LiveMatchTab.allCases.map(\.rawValue), selected: $roomTab)
        if roomTab > 0, LiveMatchTab.allCases.indices.contains(roomTab - 1) {
          LiveMatchPane(store: matchStore, tab: LiveMatchTab.allCases[roomTab - 1]) { transport.player?.pause() }
            .frame(maxHeight: .infinity)
        } else {
          chatFeed(bubbles: false)
        }
      } else {
        chatFeed(bubbles: false)
      }
    }
    .frame(maxHeight: .infinity)
  }
  /// The room's chat on its dark background (or on bubbles over a portrait stream).
  private func chatFeed(bubbles: Bool) -> some View {
    VStack(spacing: 0) {
      if let err = chat.status {
        HStack(spacing: 8) {
          Text(err).font(.footnote).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
          Button("重新连接弹幕") { chatReload += 1 }.font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 14).padding(.vertical, 6)
      }
      LiveChatFeed(lines: visible, anchor: identity?.uid, bubbles: bubbles) { line in
        guard let room = identity?.room_id, line.room == room else { return }
        let paid = line.paidID.flatMap { id in
          chat.paid.items.first { $0.id == id && $0.uid == line.uid }
        }
        selectedMessage = .init(line: line, paid: paid, room: room, owner: accounts.state.active)
      }
    }
  }
  /// The room's row over the top of the fullscreen picture: title, audience and the room's tools,
  /// clear of the island and of the lock in the top trailing corner.
  private var fullscreenInfo: some View {
    let insets = WindowMetrics.safeInsets
    return HStack(spacing: 14) {
      VStack(alignment: .leading, spacing: 2) {
        Text(roomTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
        HStack(spacing: 8) {
          if let count = chat.online { Text("在线 " + count.formatted()) }
          LiveStartedLabel(timestamp: liveStarted)
        }
        .font(.caption).foregroundStyle(.white.opacity(0.75))
      }
      Spacer(minLength: 12)
      if let player, allowCapture, !audioOnly { CaptureButton(player: player) }
      if identity != nil {
        Button { expandedChat = true } label: { Image(systemName: "text.bubble") }.accessibilityLabel("聊天")
      }
      moreMenu
    }
    .font(.system(size: 18, weight: .medium))
    .foregroundStyle(.white)
    .tint(.white)
    .padding(.leading, max(16, insets.leading))
    // Clear of the player's own clock and battery at the top trailing edge, and of the lock.
    .padding(.trailing, max(16, insets.trailing) + 84 + (allowLock ? 48 : 0))
    .padding(.top, max(10, insets.top))
    .padding(.bottom, 26)
    .background(LinearGradient(colors: [.black.opacity(0.6), .clear], startPoint: .top, endPoint: .bottom))
    .environment(\.colorScheme, .dark)
  }
  @ViewBuilder private var anchorBar: some View {
    if let identity {
      LiveAnchorBar(room: identity, info: header, watched: chat.watched, online: chat.online,
        started: liveStarted) { ranks = true }
    } else if let resolvingError {
      Button("重新读取房间") { resolveAttempt += 1 }.accessibilityHint(resolvingError)
        .foregroundStyle(.white).padding(12)
    }
  }
  @ViewBuilder private var conversation: some View {
    let visible = self.visible
    if let online = chat.online { Label("在线 " + online.formatted(),systemImage:"person.2").font(.caption).padding(.horizontal) }
    if let n = chat.popularity, n > 0 {
      Label("直播人气 " + String(n), systemImage: "person.2").piliFont(.caption).padding(
        .horizontal)
    }
    if let err = chat.status {
      HStack {
        Text(err).piliFont(.caption).foregroundStyle(.secondary)
        Button("重新连接弹幕") { chatReload += 1 }
      }.padding(.horizontal)
    }
    ScrollViewReader { proxy in
      List(visible) { line in
        Button {
          guard let room = identity?.room_id, line.room == room else { return }
          let paid = line.paidID.flatMap { id in
            chat.paid.items.first { $0.id == id && $0.uid == line.uid }
          }
          selectedMessage = .init(line: line, paid: paid, room: room, owner: accounts.state.active)
        } label: {
          LiveMessageRow(line: line, anchor: identity?.uid)
        }.buttonStyle(.plain).id(line.id)
          .onAppear {
            if readingOlder, line.id == visible.last?.id { readingOlder = false }
          }
      }
      .listStyle(.plain)
      .simultaneousGesture(
        DragGesture(minimumDistance: 16).onChanged { drag in
          if drag.translation.height > 16 { readingOlder = true }
        }
      )
      .overlay(alignment: .bottomTrailing) {
        if readingOlder {
          Button("回到底部") {
            readingOlder = false
            if let last = visible.last { proxy.scrollTo(last.id, anchor: .bottom) }
          }.buttonStyle(.borderedProminent).padding(8)
        }
      }.onChange(of: visible.last?.id) { _, n in
        if let n, !readingOlder, selectedMessage == nil { proxy.scrollTo(n, anchor: .bottom) }
      }
    }
    if let identity {
      LiveComposer(room: identity.room_id, reply: $replyTo)
        .id("\(identity.room_id):\(accounts.state.active ?? "")")
    } else if let resolvingError {
      Button("重新读取房间") { resolveAttempt += 1 }.accessibilityHint(resolvingError)
    }
  }
  /// The room after the original client and PiliPlus: a dark page over the stream's blurred cover.
  /// Portrait, the picture on top, then the anchor, the chat and the input bar; a portrait stream
  /// fills the page with the chat laid over its lower part; landscape (`_buildBodyH`), the
  /// picture on the left and chat on the right, at most 400 pt wide.
  private var screen: some View {
    GeometryReader { geometry in
    let w = geometry.size.width, h = geometry.size.height
    let pictureHeight = min(w * 9 / 16, max(80, h * 0.38))
    let wide = h > 0 && w / h >= 1.2 && w >= 540
    // The chat column keeps room for its tabs and input bar (about 340 pt) on narrow wide windows
    // such as an open iPhone Duo; the picture takes the rest, up to two thirds.
    let chatWidth = min(400, max(min(340, w * 0.42), w - min(0.66, max(0.56, h / w * 1.08)) * w))
    let sideHeight = min((w - chatWidth) * 9 / 16, max(120, h - 96))
    let portraitStream = h > w && streamSize.height > streamSize.width
    // Where the picture goes in each layout. The player itself is always the first child of the
    // same stack: moving it between branches rebuilt it, which undid entering fullscreen.
    let picture: CGSize = enlarged ? CGSize(width: w, height: h)
      : wide ? CGSize(width: w - chatWidth, height: sideHeight)
      : portraitStream ? CGSize(width: w, height: max(1, h - 58))
      : CGSize(width: w, height: pictureHeight)
    let bottomInset = enlarged ? 0 : geometry.safeAreaInsets.bottom
    ZStack(alignment: .topLeading) {
      theater.frame(width: picture.width, height: picture.height).clipped().background(.black)
        // No bar over the room: back and the title sit on the picture, as in the official room.
        // Set here, not on the page, so the panels' own stacks keep their bars.
        .toolbar(.hidden, for: .navigationBar)
      if enlarged {
        // Fullscreen: the picture takes the whole screen; the room's row lies over its top on a
        // shade and comes and goes with the player's controls.
        if !locked && fullscreenControls {
          fullscreenInfo.frame(width: w).transition(.opacity)
        }
      } else if wide {
        HStack(alignment: .top, spacing: 0) {
          VStack(alignment: .leading, spacing: 0) {
            playerTopBar.frame(height: picture.height, alignment: .top)
            anchorBar
            Spacer(minLength: 0)
          }.frame(width: picture.width)
          Rectangle().fill(.white.opacity(0.08)).frame(width: 0.5)
          VStack(spacing: 0) {
            roomBody
            bottomBar
          }
          .frame(width: chatWidth - 0.5).frame(maxHeight: .infinity)
        }
      } else if portraitStream {
        // A portrait stream: the picture fills the page, chat over its lower third, 55 pt left
        // above the input bar for the player's own row (PiliPlus's `_buildPP`).
        VStack(spacing: 0) {
          VStack(spacing: 0) {
            playerTopBar
            anchorBar
          }
          .background(LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom))
          Spacer(minLength: 0)
          chatFeed(bubbles: true)
            .frame(height: h * 0.32)
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.18)],
              startPoint: .top, endPoint: .bottom))
          Color.clear.frame(height: 55).allowsHitTesting(false)
          bottomBar
        }
        .frame(width: w, height: h)
      } else {
        // The official room: picture, anchor, the room's tabs, their page and the input bar.
        VStack(spacing: 0) {
          playerTopBar.frame(height: picture.height, alignment: .top)
          anchorBar
          if matchStore == nil { Rectangle().fill(.white.opacity(0.08)).frame(height: 0.5) }
          roomBody
          bottomBar
        }
        .frame(width: w, height: h, alignment: .top)
      }
      if enlarged, keyboardChat, let room = identity?.room_id {
        composerBar(room: room).frame(width: w).frame(maxHeight: .infinity, alignment: .bottom)
      }
      panelLayer(w: w, h: h + bottomInset, picture: picture, wide: wide, portraitStream: portraitStream)
    }
    .animation(.easeOut(duration: 0.2), value: fullscreenControls)
    .animation(.snappy(duration: 0.3), value: roomPanel)
    .animation(.snappy(duration: 0.25), value: keyboardChat)
    .frame(width: w, height: h)
    .onPreferenceChange(PlayerControlsVisibleKey.self) { shown in
      if fullscreenControls != shown { fullscreenControls = shown }
    }
    // The status bar over the picture stays black, as in the official room.
    .background(alignment: .top) {
      if !enlarged { Color.black.frame(height: 1).ignoresSafeArea(edges: .top) }
    }
    .background { if !enlarged { LiveRoomBackdrop(url: header?.room_info?.cover.flatMap(httpsURL)) } }
    .environment(\.colorScheme, enlarged ? colorScheme : .dark)
    }.overlay(alignment:.topTrailing){
      if enlarged && (allowLock || locked) {
        Button {TouchFeedback.light(); locked.toggle()} label:{
          Image(systemName:locked ? "lock.fill":"lock.open").padding(9).foregroundStyle(.white).background(.black.opacity(0.6),in:Circle())
        }.accessibilityLabel(locked ? "解锁播放控件":"锁定播放控件").padding(6)
      }
    }.background {
      if enlarged {TheaterGeometry(mode:FullscreenMode(rawValue:orientation) ?? .video,size:player?.currentItem?.presentationSize ?? .zero).allowsHitTesting(false)}
    }.onChange(of:allowLock){ _,on in if !on {locked=false} }
      .onChange(of:enlarged){ _,on in if !on{locked=false} }
      .modifier(PlaybackEdgeInsets(fullscreen: enlarged))
      .toolbar(enlarged ? .hidden : .automatic, for: .tabBar)
      // The bar sits on the room's dark backdrop.
      .toolbarBackground(.hidden, for: .navigationBar)
      .toolbarColorScheme(.dark, for: .navigationBar)
      .navigationTitle(roomTitle)
      .navigationBarTitleDisplayMode(.inline)
      .task(id: "\(identity?.room_id ?? 0):\(accounts.state.active ?? "")") {
        shield = nil
        guard let identity, let user = accounts.state.active else { return }
        let fresh = try? await BiliAPI.shared.shield(room: identity.room_id, user: user)
        if !Task.isCancelled, shield == nil { shield = fresh }
      }
  }
  private func actions(_ selection: LiveActionSelection) -> some View {
    LiveChatActions(selection: selection, shield:$shield) { target in
      if target.room == identity?.room_id && target.account == accounts.state.active { replyTo = target }
    }
  }
  private var panels: some View {
    screen
    .onChange(
      of:
        "\(identity?.room_id ?? 0):\(accounts.state.active ?? ""):\(accounts.state.owner(.role(.heartbeat)) ?? "")"
    ) { _, _ in
      selectedMessage = nil
      replyTo = nil
      editShield = false
      showPaid = false
      readingOlder = false
      liveTrack.clear()
      liveInspector.locate = nil
      liveInspector.pick = nil
    }
    .onChange(of: liveInspector.pick?.id) { _, id in
      guard id != nil, let pick = liveInspector.pick else { return }
      liveInspector.pick = nil
      guard let line = liveTrack.line(for: pick.bullet), let room = identity?.room_id,
        line.room == room, shield?.hides(line) != true
      else { return }
      selectedMessage = .init(line: line, paid: nil, room: room, owner: accounts.state.active)
    }
    .onChange(of: paidMode, initial: true) { _, mode in
      chat.configurePaid(SuperChatDisplay(rawValue: mode) ?? .current)
      if mode == 2 { showPaid = false }
    }
    .task(id: "\(identity?.room_id ?? 0):\(header?.room_info?.parent_area_id ?? 0)") {
      // Official match rooms sit under 赛事; find the season they carry for the match tabs.
      guard let room = identity?.room_id, header?.room_info?.parent_area_id == 13 else {
        matchStore = nil; roomTab = 0
        return
      }
      if matchStore.map({ $0.contest.liveRoom == room }) == true { return }
      let found = try? await EsportsService.contest(forRoom: room)
      if !Task.isCancelled, identity?.room_id == room {
        matchStore = found.map { LiveMatchStore(contest: $0) }
        roomTab = 0
      }
    }
  }
  var body: some View {
    panels.task(id: "\(identity?.room_id ?? 0):\(headerOwner ?? ""):\(headerRevision)") {
      liveCard = nil; header = nil; headerUnavailable = false
      guard let identity else { return }
      let user = headerOwner
      if let info = try? await BiliAPI.shared.read(
        "/xlive/web-room/v1/index/getH5InfoByRoom", ["room_id": String(identity.room_id)],
        host: "api.live.bilibili.com", expectedAccount: user ?? "", as: LiveRoomHeader.self),
        !Task.isCancelled, user == headerOwner, self.identity?.room_id == identity.room_id {
        header = info
        let text = chat.roomTitle ?? info.room_info?.title ?? title, author = info.anchor_info?.base_info?.uname
        let cover = info.room_info?.cover.flatMap(httpsURL)
        liveCard = .init(.live, id: String(identity.room_id), title: text, author: author,
          authorID: String(identity.uid), thumb: cover)
        transport.updateRoom(identity.room_id, title: text, artist: author, cover: cover)
      } else if !Task.isCancelled, user == headerOwner { headerUnavailable = true }
    }
    .task(id: "\(id):\(resolveAttempt)") {
      resolvingError = nil
      identity = nil
      do {
        let info = try await BiliAPI.shared.read(
          "/room/v1/Room/room_init", ["id": String(id)], host: "api.live.bilibili.com",
          as: LiveRoomIdentity.self)
        try Task.checkCancellation()
        identity = info
      } catch { if !Task.isCancelled { resolvingError = error.localizedDescription } }
    }
    .task(id: "\(identity?.room_id ?? 0):\(accounts.state.owner(.role(.heartbeat)) ?? ""):\(recordVisits)") {
      guard recordVisits, let room = identity?.room_id, room > 0,
        let owner = accounts.state.owner(.role(.heartbeat)) else { return }
      let key = "\(owner):\(room)"
      guard visitAttempts.insert(key).inserted else { return }
      try? await BiliAPI.shared.recordLiveVisit(room: room, owner: owner)
    }
    .onChange(of: chat.roomTitle) { _,latest in
      guard let room=identity?.room_id, let latest else {return}
      liveCard = .init(.live,id:String(room),title:latest,author:header?.anchor_info?.base_info?.uname,
        authorID:identity.map{String($0.uid)},thumb:header?.room_info?.cover.flatMap(httpsURL))
      transport.updateRoom(room,title:latest,artist:header?.anchor_info?.base_info?.uname,cover:header?.room_info?.cover.flatMap(httpsURL))
    }
    .onChange(of: preferences.background) { _, _ in transport.setSessionPreferences(preferences) }
    .onChange(of: preferences.controls) { _, _ in transport.setSessionPreferences(preferences) }
    .task(id: "\(qn ?? 0):\(reload):\(identity?.room_id ?? 0):\(audioOnly):\(headerOwner ?? "")") {
      transport.stop()
      liveStarted = nil
      error = nil
      guard let room = identity?.room_id, room > 0 else { return }
      let owner = headerOwner ?? ""
      do {
        let rules = NetworkMediaRules.current()
        let preferred = qn ?? (MediaNetwork.shared.cellular ? rules.cellLive : rules.wifiLive)
        let s = try await BiliAPI.shared.liveStream(room, quality: preferred, audioOnly: audioOnly, owner: owner)
        try Task.checkCancellation()
        guard owner == (headerOwner ?? ""), self.identity?.room_id == room else { return }
        liveStarted = s.live_status == 1 ? s.live_time : nil
        upscale.begin(id: "live:" + String(identity?.room_id ?? id), anime: false)
        transport.setSessionPreferences(preferences)
        transport.open(s, room: room, audioOnly: audioOnly, title: roomTitle, artist: header?.anchor_info?.base_info?.uname, cover: header?.room_info?.cover.flatMap(httpsURL))
      } catch { if !Task.isCancelled { self.error = error.localizedDescription } }
    }
    .task(
      id:
        "\(identity?.room_id ?? 0):\(chatReload):\(accounts.state.owner(.role(.heartbeat)) ?? "")"
    ) {
      if let identity {
        await chat.connect(identity.room_id, reader: accounts.state.owner(.role(.heartbeat)))
      } else {
        chat.close()
      }
    }
    .onDisappear {
      if !expandedChat && !keyboardChat && !showFacts && !editShield && !paidSettings
        && !showPaid && !ranks && selectedMessage == nil {
        chat.close()
        transport.stop()
      }
    }
  }
  private func qualityName(_ q: Int) -> String {
    PlaybackOption.liveName(q)
  }
}
