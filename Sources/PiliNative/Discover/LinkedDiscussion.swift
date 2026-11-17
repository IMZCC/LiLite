import SwiftUI

struct LinkedReply: Hashable { let root: Int64, anchor: Int64? }
private struct LinkedReplyKey: EnvironmentKey { static let defaultValue: LinkedReply? = nil }
extension EnvironmentValues {
  var linkedReply: LinkedReply? {
    get { self[LinkedReplyKey.self] }
    set { self[LinkedReplyKey.self] = newValue }
  }
}

private struct LinkedDiscussion: ViewModifier {
  let oid: Int64?, type: Int, author: Int64?, playback: ReplyPlaybackTarget?
  let selectComments:(()->Void)?
  @Environment(\.linkedReply) private var requested
  @EnvironmentObject private var accounts: AccountContext
  private struct Thread:Identifiable {
    let id=UUID(), oid:Int64, type:Int, author:Int64?, reader:String?, link:LinkedReply
  }
  @State private var consumed:LinkedReply?
  @State private var sheet:Thread?
  func body(content: Content) -> some View {
    content.environment(\.linkedReply, nil)
      .task(id: "\(oid ?? 0):\(type):\(requested?.root ?? 0):\(requested?.anchor ?? 0):\(accounts.state.active ?? "")") {
        if let old=sheet,old.oid != oid || old.type != type || old.reader != accounts.state.active || old.link != requested {sheet=nil}
        guard let oid,oid>0,type>0,let requested,consumed != requested else{return}
        consumed=requested;selectComments?()
        sheet=Thread(oid:oid,type:type,author:author,reader:accounts.state.active,link:requested)
      }
      .piliSheet(item:$sheet){target in
        if target.oid==oid,target.type==type,target.reader==accounts.state.active {
          PiliNavigationStack {
            Discussion(oid:target.oid,type:target.type,root:target.link.root,owner:target.author,anchor:target.link.anchor)
              .environment(\.replyPlayback,playback)
              .toolbar{ToolbarItem(placement:.confirmationAction){Button("完成"){sheet=nil}}}
          }
        }
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
      if let text { Text(text).textSelection(.enabled) }
      if let uid = accounts.state.active {
        Button("查看创作者公示信息") { Task { await read(owner:uid) } }.disabled(busy)
      } else { NavigationLink("登录后查看") { QRLoginView() } }
    }.navigationTitle("创作者公示").onChange(of: accounts.state.active) { _,_ in text = nil }
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
