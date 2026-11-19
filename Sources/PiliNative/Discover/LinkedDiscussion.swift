import SwiftUI

struct LinkedReply: Hashable { let root: Int64, anchor: Int64? }
private struct LinkedReplyKey: EnvironmentKey { static let defaultValue: LinkedReply? = nil }
extension EnvironmentValues {
  var linkedReply: LinkedReply? {
    get { self[LinkedReplyKey.self] }
    set { self[LinkedReplyKey.self] = newValue }
  }
}

/// A thread a link asked for, handed to the page's own comment list once. The video detail's
/// embedded comments open it the way a tap on a floor does (the panel under the player), as the
/// original's videoPush(rootRpId:, secondRpId:) does.
final class PendingReplyThread {
  let oid: Int64, link: LinkedReply
  private(set) var consumed = false
  init(oid: Int64, link: LinkedReply) { self.oid = oid; self.link = link }
  @MainActor func take(oid: Int64) -> LinkedReply? {
    guard !consumed, oid == self.oid else { return nil }
    consumed = true
    return link
  }
}
private struct PendingReplyThreadKey: EnvironmentKey { static let defaultValue: PendingReplyThread? = nil }
extension EnvironmentValues {
  var pendingReplyThread: PendingReplyThread? {
    get { self[PendingReplyThreadKey.self] }
    set { self[PendingReplyThreadKey.self] = newValue }
  }
}

private struct LinkedDiscussion: ViewModifier {
  let oid: Int64?, type: Int, author: Int64?, playback: ReplyPlaybackTarget?
  let selectComments:(()->Void)?
  @Environment(\.linkedReply) private var requested
  @EnvironmentObject private var accounts: AccountContext
  private struct Thread:Identifiable, Hashable {
    let id=UUID(), oid:Int64, type:Int, author:Int64?, reader:String?, link:LinkedReply
  }
  @State private var consumed:LinkedReply?
  @State private var pending:PendingReplyThread?
  @State private var page:Thread?
  func body(content: Content) -> some View {
    content.environment(\.linkedReply, nil)
      .environment(\.pendingReplyThread, pending)
      .task(id: "\(oid ?? 0):\(type):\(requested?.root ?? 0):\(requested?.anchor ?? 0):\(accounts.state.active ?? "")") {
        guard let oid,oid>0,type>0,let requested,consumed != requested else{return}
        consumed=requested
        if let selectComments {
          // Pages with embedded comments (video, episode): switch to them and let the list
          // open the thread as its own floor panel. No sheet over the page.
          pending=PendingReplyThread(oid:oid,link:requested)
          selectComments()
        } else {
          // Elsewhere the original pushes the reply page.
          page=Thread(oid:oid,type:type,author:author,reader:accounts.state.active,link:requested)
        }
      }
      .navigationDestination(item:$page){target in
        Discussion(oid:target.oid,type:target.type,root:target.link.root,owner:target.author,anchor:target.link.anchor)
          .environment(\.replyPlayback,playback)
      }
  }
}
extension View {
  func linkedDiscussion(oid:Int64?,type:Int,author:Int64?,playback:ReplyPlaybackTarget?=nil,selectComments:(()->Void)?=nil)->some View {
    modifier(LinkedDiscussion(oid:oid,type:type,author:author,playback:playback,selectComments:selectComments))
  }
}

struct LinkedFollowed: View {
  let mid: Int64
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    if let uid = accounts.state.active {
      SharedFollowing(mid: mid, uid: uid, alsoFollowsCreator: true).id(uid)
    } else { ContentUnavailableView("登录后查看关注关系", systemImage: "person.2") }
  }
}

struct CreatorDisclosure: View {
  let mid: Int64
  @EnvironmentObject private var accounts: AccountContext
  @State private var text: String?
  @State private var busy = false
  private struct Result: Decodable {
    struct Rejection: Decodable { let title: String?, text: String? }
    let name: String?, reject_page: Rejection?
  }
  var body: some View {
    Form {
      Section {
        if let text {
          Text(text).textSelection(.enabled)
        } else {
          Text("创作者公示包含经过认证的实名或机构信息").foregroundStyle(.secondary)
        }
      }
      Section {
        if let uid = accounts.state.active {
          Button { Task { await read(owner:uid) } } label: {
            HStack {
              SettingsRowLabel(title: "查看创作者公示信息", symbol: "person.text.rectangle", color: .blue)
              if busy { Spacer(); ProgressView() }
            }
          }.disabled(busy)
        } else {
          NavigationLink { DeferredPage { QRLoginView() } } label: {
            SettingsRowLabel(title: "登录后查看", symbol: "person.crop.circle", color: .gray)
          }
        }
      }
    }.navigationTitle("创作者公示").navigationBarTitleDisplayMode(.inline).onChange(of: accounts.state.active) { _,_ in text = nil }
  }
  @MainActor private func read(owner: String) async {
    guard !busy else { return }
    busy = true; defer { busy = false }
    do {
      guard let account = try await AccountJar.shared.current(credentials:.both), account.id == owner else { return }
      var p = ["up_mid":String(mid)]; p["access_key"] = account.mobileToken
      let value = try await BiliAPI.shared.read("/x/member/app/up/realname", p, expectedAccount:owner, as:Result.self)
      guard accounts.state.active == owner else { return }
      if let name = value.name, !name.isEmpty { text = name }
      else { text = [value.reject_page?.title, value.reject_page?.text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator:"\n")
        if text?.isEmpty != false { text = "没有可展示的公示信息" }
      }
    } catch { if accounts.state.active == owner { text = error.localizedDescription } }
  }
}
