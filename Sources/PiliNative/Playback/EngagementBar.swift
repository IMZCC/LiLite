import SwiftUI
import UIKit

@MainActor enum TouchFeedback {
  private static var gate = TouchPulseGate()
  static func light() {
    guard gate.claim(enabled: UserDefaults.standard.bool(forKey: "ui.haptics")) else { return }
    UIImpactFeedbackGenerator(style: .light).impactOccurred()
    DispatchQueue.main.async { gate.nextTurn() }
  }
}
extension View {
  func piliTapFeedback() -> some View {
    simultaneousGesture(TapGesture().onEnded { TouchFeedback.light() })
  }
}
extension Binding where Value == Bool {
  @MainActor var withTouchFeedback: Binding<Bool> {
    Binding(get: { wrappedValue }, set: { value in
      guard value != wrappedValue else { return }
      wrappedValue = value
      TouchFeedback.light()
    })
  }
}
/// Public counters shown under the engagement icons. Optional: overlays omit them.
struct EngagementCounts: Equatable { var like: Int?, coin: Int?, favorite: Int? }
struct EngagementBar: View {
  let item: EngagementItem
  var keyboard:PlayerKeyTicket?=nil
  var counts: EngagementCounts? = nil
  /// Extra columns appended to the same evenly spaced row (cache, later, share).
  var extras: AnyView? = nil
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    ScopedEngagement(item:item,keyboard:keyboard,counts:counts,extras:extras).id(item.key + ":" + (accounts.state.active ?? "")+":"+(keyboard?.scope ?? "tap"))
  }
}
private struct EngagementFillsKey: EnvironmentKey { static let defaultValue = false }
private struct EngagementCompactKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var engagementFills: Bool {
    get { self[EngagementFillsKey.self] }
    set { self[EngagementFillsKey.self] = newValue }
  }
  /// Icon-only columns on a dark video background (the fullscreen action row).
  var engagementCompact: Bool {
    get { self[EngagementCompactKey.self] }
    set { self[EngagementCompactKey.self] = newValue }
  }
}
struct ArchiveActionColumn: View {
  let symbol: String, title: String, active: Bool
  @Environment(\.engagementFills) private var fills
  @Environment(\.engagementCompact) private var compact
  var body: some View {
    if compact {
      Image(systemName: symbol).font(.system(size: 19, weight: .medium))
        .foregroundStyle(active ? Color.accentColor : Color.white)
        .frame(width: 42, height: 40).contentShape(Rectangle())
        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
        .contentTransition(.symbolEffect(.replace))
    } else {
      column
    }
  }
  private var column: some View {
    VStack(spacing: 5) {
      Image(systemName: symbol).font(.system(size: 21, weight: .regular))
        .frame(height: 26)
      Text(title).font(.caption).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
    }
    .foregroundStyle(active ? Color.accentColor : Color.primary)
    .frame(minWidth: 56, maxWidth: fills ? .infinity : 64, minHeight: 52).contentShape(Rectangle())
  }
}
private struct ScopedEngagement: View {
  let item: EngagementItem
  var keyboard:PlayerKeyTicket?=nil
  var counts: EngagementCounts? = nil
  var extras: AnyView? = nil
  private func caption(_ fallback: String, _ n: Int?) -> String {
    guard let n, n > 0 else { return fallback }
    return n.formatted(.number.notation(.compactName))
  }
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.accessibilityReduceMotion) private var reduce
  @AppStorage("detail.quickFav") private var quick = false
  @AppStorage("detail.quickFolder") private var preferred = ""
  @State private var state = VideoEngagement()
  @State private var active=true
  @State private var received=false
  @State private var coins = false
  @State private var confirmTriple = false
  @State private var clearFolders = false
  @State private var pick = false
  @State private var busy = false
  @State private var alert: String?
  @State private var animation = 0
  @State private var coinAnimation = 0
  @State private var refresh = 0
  @State private var revision = 0
  private var uid: String? { accounts.state.active }
  var body: some View {
    Group{if keyboard != nil {Color.clear.frame(width:1,height:1).accessibilityHidden(true)}else{HStack(spacing: 0) {
      ArchiveActionColumn(symbol: state.liked ? "hand.thumbsup.fill" : "hand.thumbsup",
        title: caption("赞", counts?.like), active: state.liked)
        .accessibilityLabel("赞")
        .overlay{TripleTouch(owner:item.key+":"+(uid ?? "")){effect in
          switch effect{case .like:Task{await like()}
          case .armTriple:TouchFeedback.light()
          case .triple:Task{await commitHeldTriple()}
          default:break}
        }.accessibilityHidden(true)}
        .accessibilityAddTraits(.isButton).accessibilityAction { Task { await like() } }
        .accessibilityAction(named: "一键三连") { askForTriple() }
        .symbolEffect(.bounce, value: reduce ? 0 : animation)
      if item.episode == nil {
        Button{Task{await dislike()}}label:{
          ArchiveActionColumn(symbol: state.disliked ? "hand.thumbsdown.fill":"hand.thumbsdown",
            title: "不喜欢", active: state.disliked)
        }.accessibilityLabel(state.disliked ? "取消点踩":"点踩")
      }
      Button {
        if uid == nil {
          alert = "请先登录"
        } else if state.coins >= item.maxCoins {
          alert = "已经投过币了"
        } else {
          coins = true
        }
      } label: {
        ArchiveActionColumn(symbol: state.contributed ? "circle.circle.fill" : "circle.circle",
          title: caption("投币", counts?.coin), active: state.contributed)
      }.accessibilityLabel("投币")
      .symbolEffect(.bounce, value: reduce ? 0 : coinAnimation)
      if let rid = item.rid, let uid {
        Button {
          if quick { Task { await quickFavorite(rid, uid) } } else { pick = true }
        } label: {
          ArchiveActionColumn(symbol: state.starred ? "star.fill" : "star",
            title: caption("收藏", counts?.favorite), active: state.starred)
        }.accessibilityLabel("收藏")
        .contextMenu { Button("选择收藏夹") { pick = true } }
        .symbolEffect(.bounce, value: reduce ? 0 : animation)
      }
      if let extras { extras }
    }.environment(\.engagementFills, counts != nil)}}.buttonStyle(.plain).disabled(busy)
      .id(item.key)
      .onAppear{active=true}.onDisappear{active=false;revision+=1}
      .task(id: "\(uid ?? ""):\(item.key):\(refresh)") { if keyboard==nil {await load()} }
      .task(id:keyboard?.id){if let keyboard{await shortcut(keyboard)}}
      .onReceive(NotificationCenter.default.publisher(for:PlayerKeyMemory.changed)){n in
        if keyboard==nil,n.userInfo?["item"] as? String == item.key,n.userInfo?["owner"] as? String == uid{refresh+=1}
      }
      .onChange(of: uid) { _, _ in
        coins = false
        confirmTriple = false
        clearFolders = false
        pick = false
        alert = nil
        state = .init()
        revision += 1
        refresh += 1
      }
      .piliSheet(isPresented: $pick, onDismiss: { refresh += 1 }) {
        if let rid = item.rid, let uid {
          PiliNavigationStack { PickFolder(uid: uid, aid: rid, resourceType: item.type) }
        }
      }
      .piliSheet(isPresented:$coins){
        if let owner=uid{
          ArchiveCoinPicker(owner:owner,already:state.coins,maximum:item.maxCoins){amount,withLike in
            Task{guard uid==owner else{return};await coin(amount,withLike:withLike)}
          }
        }
      }
      .confirmationDialog("一键三连", isPresented: $confirmTriple, titleVisibility: .visible) {
        Button("点赞、投币并收藏") { Task { await triple() } }
        Button("取消", role: .cancel) {}
      } message: {
        Text("将为这个视频投币，最多 2 枚")
      }
      .confirmationDialog("从所有收藏夹移除？", isPresented: $clearFolders, titleVisibility: .visible) {
        Button("移除收藏", role: .destructive) { Task { await removeFavorites() } }
        Button("取消", role: .cancel) {}
      }
      .alert("视频", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
        Button("好") {}
      } message: {
        Text(alert ?? "")
      }
  }
  @MainActor private func shortcut(_ ticket:PlayerKeyTicket)async{
    guard active,uid==ticket.owner,!busy else{return}
    switch ticket.effect{case .like,.coin,.favorite,.triple:break;default:return}
    await load(report:true)
    guard received,!Task.isCancelled,active,accounts.state.active==ticket.owner else{return}
    switch ticket.effect{
    case .like:await like()
    case .triple:if state.complete{alert="已完成三连"}else{await triple()}
    case .coin:if state.coins>=item.maxCoins{alert="已经投过币了"}else{coins=true}
    case .favorite:if let rid=item.rid{await quickFavorite(rid,ticket.owner,shortcut:true)}
    default:break
    }
  }
  @MainActor private func commitHeldTriple()async{
    guard uid != nil else{alert="请先登录";return}
    if !received{await load(report:true)}
    guard active,!Task.isCancelled,received else{return}
    if state.complete{alert="已完成三连"}else{await triple()}
  }
  private func askForTriple() {
    TouchFeedback.light()
    if uid == nil {
      alert = "请先登录"
    } else if state.complete {
      alert = "已完成三连"
    } else {
      confirmTriple = true
    }
  }
  @MainActor private func load(report:Bool=false) async {
    received=false
    let epoch = revision
    guard let uid else {
      state = .init()
      return
    }
    do {
      let r: VideoEngagement
      if let ep = item.episode {
        r = try await BiliAPI.shared.read(
          "/pgc/season/episode/community", ["ep_id": String(ep)], expectedAccount: uid,
          as: VideoEngagement.self)
      } else {
        r = try await BiliAPI.shared.read(
          "/x/web-interface/archive/relation", ["bvid": item.bvid], expectedAccount: uid,
          as: VideoEngagement.self)
      }
      try Task.checkCancellation()
      if self.uid == uid && active && !busy && epoch == revision { state = r;received=true }
    } catch {
      if !Task.isCancelled && self.uid == uid && active && epoch == revision && !busy { state = .init();if report{alert=error.localizedDescription} }
    }
  }
  @MainActor private func perform(_ body: (String) async throws -> Void) async {
    guard let uid else {
      alert = "请先登录"
      return
    }
    guard active,!Task.isCancelled,!busy else { return }
    busy = true
    revision += 1
    defer { busy = false }
    do { try await body(uid) } catch {
      if !Task.isCancelled && self.uid == uid { alert = error.localizedDescription }
    }
  }
  @MainActor private func didCommit(_ owner:String){
    if uid==owner{NotificationCenter.default.post(name:PlayerKeyMemory.changed,object:nil,userInfo:["item":item.key,"owner":owner])}
  }
  @MainActor private func like() async {
    guard uid != nil else{alert="请先登录";return}
    if !received{await load(report:true)}
    guard active,received,!Task.isCancelled else{return}
    let next = !state.liked
    await perform { uid in
      let request=try PlaybackSocialRequest.like(item,on:next)
      try await BiliAPI.shared.submit(request.path,request.fields,expectedAccount:uid)
      if self.uid == uid {
        state.liked = next;if next{state.disliked=false};didCommit(uid)
        TouchFeedback.light()
      }
    }
  }
  @MainActor private func dislike()async{
    guard let uid else{alert="请先登录";return}
    guard item.episode==nil,let aid=item.aid ?? ArchiveNumber.av(item.bvid) else{return}
    if !received{await load(report:true)}
    guard active,received,!Task.isCancelled,self.uid==uid else{return}
    let next = !state.disliked
    await perform{owner in
      try await BiliAPI.shared.archiveDislike(aid,undo:!next,owner:owner)
      if self.uid==owner{state.disliked=next;if next{state.liked=false};didCommit(owner);TouchFeedback.light()}
    }
  }
  @MainActor private func coin(_ n: Int,withLike:Bool) async {
    guard n > 0 && n <= item.maxCoins - state.coins else { return }
    await perform { uid in
      let request=try PlaybackSocialRequest.coin(item,amount:n,already:state.coins,withLike:withLike)
      try await BiliAPI.shared.submit(request.path,request.fields,expectedAccount:uid)
      if self.uid == uid {
        state.coins += n;didCommit(uid)
        state.liked = state.liked || withLike
        if state.liked{state.disliked=false}
        coinAnimation += 1
        TouchFeedback.light()
        alert = "已投 \(n) 枚硬币"
      }
    }
  }
  @MainActor private func triple() async {
    await perform { uid in
      let request=try PlaybackSocialRequest.triple(item)
      let raw=try await BiliAPI.shared.submitResponse(request.path,request.fields,expectedAccount:uid)
      struct Response: Decodable { let data: VideoEngagement }
      let result = try JSONDecoder().decode(Response.self, from: raw).data
      if self.uid == uid {
        state.addTriple(result);didCommit(uid)
        animation += 1
        coinAnimation += 1
        alert =
          state.complete
          ? "三连成功"
          : "点赞：" + (state.liked ? "已完成" : "未完成") + "，投币：" + (state.contributed ? "已完成" : "未完成")
            + "，收藏：" + (state.starred ? "已完成" : "未完成")
      }
    }
  }
  @MainActor private func quickFavorite(_ rid: Int64, _ account: String,shortcut:Bool=false) async {
    await perform { uid in
      guard account == uid else { throw ServiceError("账号已切换") }
      let rows = try await BiliAPI.shared.folders(
        uid: uid, videoID: rid, resourceType: item.type, expectedAccount: uid)
      guard active,self.uid == uid,!Task.isCancelled else { return }
      guard rows.allSatisfy({ $0.fav_state == 0 || $0.fav_state == 1 }) else {
        throw ServiceError("无法读取收藏状态")
      }
      if rows.contains(where: { $0.fav_state == 1 }) {
        state.starred = true
        if shortcut { try await removeFavoriteReceipt(rid,owner:uid) }
        else {clearFolders = true}
        return
      }
      guard let folder = rows.first(where: { String($0.id) == preferred }) ?? rows.first else {
        pick = true
        return
      }
      try await BiliAPI.shared.submit(
        "/x/v3/fav/resource/batch-deal",
        ["resources": "\(rid):\(item.type)", "add_media_ids": String(folder.id)],
        expectedAccount: uid)
      if self.uid == uid {
        state.starred = true
        didCommit(uid);alert = "已收藏到" + folder.title
      }
    }
  }
  @MainActor private func removeFavorites() async {
    guard let rid = item.rid else { return }
    await perform {uid in try await removeFavoriteReceipt(rid,owner:uid)}
  }
  @MainActor private func removeFavoriteReceipt(_ rid:Int64,owner uid:String) async throws {
    try Task.checkCancellation()
    guard active,self.uid == uid else{return}
    try await BiliAPI.shared.submit(
      "/x/v3/fav/resource/unfav-all", ["rid":String(rid),"type":String(item.type)],expectedAccount:uid)
    if self.uid==uid{state.starred=false;didCommit(uid);alert="已取消收藏"}
  }
}
struct QuickFolderChoice: View {
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("detail.quickFolder") private var folder = ""
  var body: some View {
    if let uid = accounts.state.active {
      VStack {
        Button("使用首个收藏夹") { folder = "" }
        PageList(empty: "暂无收藏夹") { _ in
          Page(items: try await BiliAPI.shared.folders(uid: uid, expectedAccount: uid), next: nil)
        } row: { (f: Folder) in
          Button {
            folder = String(f.id)
          } label: {
            HStack {
              Text(f.title)
              Spacer()
              if folder == String(f.id) { Image(systemName: "checkmark") }
            }
          }
        }.id(uid)
      }.navigationTitle("快速收藏夹")
    } else {
      ContentUnavailableView("请先登录", systemImage: "person.crop.circle")
    }
  }
}
