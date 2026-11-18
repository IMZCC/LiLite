import SwiftUI

struct BulletPick: Identifiable, Equatable {
  static func ==(lhs:Self,rhs:Self)->Bool{lhs.bullet==rhs.bullet}
  let index:Int, sample:Double, duration:Double
  let id = UUID()
  let bullet: Bullet, rect: CGRect, text: String
  init(index:Int = -1,sample:Double = 0,duration:Double = 0,bullet:Bullet,rect:CGRect,text:String){
    self.index=index;self.sample=sample;self.duration=duration
    self.bullet=bullet;self.rect=rect;self.text=text
  }
}
@MainActor final class BulletInspector: ObservableObject {
  var locate: ((CGPoint) -> BulletPick?)?
  var snapshot:(()->[Bullet])?
  var playhead:(()->Double)?
  private(set) var pauseClock=BulletPauseClock<BulletPick>()
  @Published var pick: BulletPick? {
    didSet {
      guard let now=playhead?(),now.isFinite else{pauseClock = .init();return}
      if let pick {pauseClock.hold(pick,start:pick.bullet.time,duration:pick.duration,sample:pick.sample,at:now)}
      else{pauseClock.release(at:now)}
    }
  }
  func clearTimeline() {pick=nil;pauseClock = .init()}
  func select(_ point: CGPoint) { pick = locate?(point) }
}
/// Only the visible text is a target. Taps elsewhere reach the AVKit controller.
struct BulletTapSurface: UIViewRepresentable {
  let inspector: BulletInspector
  final class Surface: UIView {
    var inspector: BulletInspector?
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
      super.point(inside: point, with: event) && inspector?.locate?(point) != nil
    }
    @objc func tapped(_ gesture: UITapGestureRecognizer) {
      inspector?.select(gesture.location(in: self))
    }
  }
  func makeUIView(context: Context) -> Surface {
    let v = Surface()
    v.backgroundColor = .clear
    v.isAccessibilityElement = false
    v.addGestureRecognizer(UITapGestureRecognizer(target: v, action: #selector(Surface.tapped(_:))))
    return v
  }
  func updateUIView(_ view: Surface, context: Context) { view.inspector = inspector }
}
@MainActor final class BulletLikes: ObservableObject {
  static let shared = BulletLikes()
  struct Key: Hashable { let uid: String, cid: Int64, id: Int64 }
  @Published private(set) var ids = Set<Key>()
  @Published private(set) var totals=[Key:Int]()
  func count(_ bullet:Bullet,cid:Int64,owner:String?)->Int {
    guard let owner,let id=bullet.entryID else{return max(0,bullet.likes ?? 0)}
    return totals[.init(uid:owner,cid:cid,id:id)] ?? max(0,bullet.likes ?? 0)
  }
  func record(_ key:Key,receipt:BulletVoteReceipt,initial:Int){
    if totals.count>4096{totals.removeAll();ids.removeAll()}
    let old=ids.contains(key)
    totals[key]=receipt.count(totals[key] ?? max(0,initial),wasLiked:old)
    if receipt.liked{ids.insert(key)}else{ids.remove(key)}
  }
}
extension BiliAPI {
  func bulletLike(id: Int64, cid: Int64, on: Bool, uid: String) async throws ->BulletVoteReceipt {
    do{try await submit(
      "/x/v2/dm/thumbup/add",
      ["oid": String(cid), "dmid": String(id), "op": on ? "1" : "2", "platform": "web_player"],
      expectedAccount: uid)
      return .applied(on)
    }catch let e as ServiceError{if let code=e.code,[65006,65004].contains(code){return try BulletVoteReceipt.reconcile(code,requested:on)};throw e}
  }
  func bulletReport(id: Int64, cid: Int64, reason: Int, body: String, block: Bool, uid: String)
    async throws
  {
    var f = [
      "cid": String(cid), "originCid": String(cid), "dmid": String(id), "reason": String(reason),
      "block": block ? "true" : "false","polaris_app_id":"100","polaris_platform":"5","spmid":"333.788.0.0","from_spmid":"333.788.0.0","statistics":#"{"appId":100,"platform":5,"abtest":"","version":""}"#,
    ]
    if !body.isEmpty { f["content"] = body }
    try BulletComplaintReceipt.verify(await submitResponse("/x/dm/report/add", f, expectedAccount: uid))
  }
}
struct BulletReportSheet: View {
  let cid:Int64,id:Int64,uid:String,sender:String?,done:(String)->Void
  @Environment(\.dismiss) private var dismiss
  @State private var reason = 1
  @State private var bodyText = ""
  @State private var block = false
  @State private var busy = false
  @State private var issue: String?
  let reasons = [
    1: "违法违禁", 2: "色情低俗", 3: "赌博诈骗", 4: "人身攻击", 5: "侵犯隐私", 6: "垃圾广告", 7: "引战", 8: "剧透", 9: "恶意刷屏",
    10: "视频无关", 11: "其它", 12: "青少年不良信息", 13: "违法信息外链",
  ]
  /// The original's report dialog: a radio list of reasons, a note for 其它, 同时屏蔽, then submit.
  var body: some View {
    PiliNavigationStack {
      List {
        Section {
          ForEach(reasons.keys.sorted(), id: \.self) { k in
            Button { TouchFeedback.light(); reason = k } label: {
              HStack(spacing: 12) {
                Image(systemName: reason == k ? "largecircle.fill.circle" : "circle")
                  .font(.system(size: 19)).foregroundStyle(reason == k ? Color.accentColor : Color.secondary)
                Text(reasons[k] ?? "").foregroundStyle(.primary)
                Spacer(minLength: 0)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        } header: { Text("请选择举报理由") }
        if reason == 11 {
          Section { TextField("请输入举报说明", text: $bodyText, axis: .vertical).lineLimit(2...5) }
        }
        if sender?.isEmpty == false {
          Section {
            Button { block.toggle() } label: {
              HStack(spacing: 12) {
                Image(systemName: block ? "checkmark.square.fill" : "square")
                  .font(.system(size: 19)).foregroundStyle(block ? Color.accentColor : Color.secondary)
                Text("拉黑该用户").foregroundStyle(.primary)
                Spacer(minLength: 0)
              }.contentShape(Rectangle())
            }.buttonStyle(.plain)
          }
        }
        if let issue { Text(issue).font(.footnote).foregroundStyle(.red).listRowBackground(Color.clear) }
      }
      .navigationTitle("举报弹幕").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) { submit }
      }
    }
    .presentationDetents([.medium, .large])
  }
  private var submit: some View {
        Button("提交") {
          Task {
            guard !busy else { return }
            busy = true
            defer { busy = false }
            do {
              try await BiliAPI.shared.bulletReport(
                id: id, cid: cid, reason: reason, body: reason == 11 ? bodyText : "", block:false,
                uid: uid)
              var message="举报已提交"
              if block,let sender,!sender.isEmpty{
                do{try await AccountBulletRules.shared.update(uid,type:2,input:sender,senderHash:true)}
                catch{message+="；屏蔽未成功："+error.localizedDescription}
              }
              done(message)
              dismiss()
            } catch { issue = error.localizedDescription }
          }
        }.disabled(
          busy || reason == 11 && bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
  }
}
/// The original's tap-on-danmaku tip: a small dark bubble under the bullet, its arrow pointing at
/// it, holding icon actions — 赞 (with the count), 复制, 撤回 for your own or 举报, and 跳转 when
/// the text names a time.
struct PinnedBullet: View {
  @ObservedObject var inspector: BulletInspector
  let cid: Int64?
  var duration = 0.0
  var seek: ((Double) -> Void)? = nil
  @EnvironmentObject private var accounts: AccountContext
  @ObservedObject private var likes = BulletLikes.shared
  @ObservedObject private var recall = BulletRecall.shared
  @State private var reporting: BulletPick?
  @State private var confirmRecall: BulletPick?
  @State private var toast: String?
  @State private var busy = false
  private let item: CGFloat = 40
  var body: some View {
    GeometryReader { geo in
      if let pick = inspector.pick, let cid {
        let jump = seek == nil ? nil : BulletTrackFrame.timeLink(pick.text, duration: duration)
        let count = 3 + (jump == nil ? 0 : 1)
        let w = CGFloat(count) * item + 8
        let x = min(max(w / 2 + 6, pick.rect.midX), geo.size.width - w / 2 - 6)
        let below = pick.rect.maxY + 6 + 44 < geo.size.height
        VStack(spacing: 0) {
          if below { arrow(up: true).offset(x: pick.rect.midX - x) }
          HStack(spacing: 0) {
            likeItem(pick, cid: cid)
            icon("doc.on.doc", "复制") {
              UIPasteboard.general.string = pick.text
              done("已复制")
            }
            if let uid = accounts.state.active, recall.owns(pick.bullet, cid: cid, author: uid) {
              icon("arrow.uturn.backward", "撤回") { confirmRecall = pick }
            } else {
              icon("exclamationmark.bubble", "举报") {
                if accounts.state.active == nil { done("请先登录") } else { reporting = pick }
              }
            }
            if let jump, let seek {
              icon("scope", "跳转到 " + clockText(jump)) { seek(jump); inspector.pick = nil }
            }
          }
          .padding(.horizontal, 4).frame(height: 38)
          .background(.black.opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
          if !below { arrow(up: false).offset(x: pick.rect.midX - x) }
        }
        .frame(width: w)
        .position(x: x, y: below ? pick.rect.maxY + 4 + 25 : pick.rect.minY - 4 - 25)
        .overlay(alignment: .top) {
          if let toast {
            Text(toast).font(.caption).foregroundStyle(.white).padding(.horizontal, 10).padding(.vertical, 6)
              .background(.black.opacity(0.7), in: Capsule())
              .position(x: geo.size.width / 2, y: 30)
          }
        }
        .confirmationDialog("撤回自己发送的这条弹幕？", isPresented: Binding(
          get: { confirmRecall != nil }, set: { if !$0 { confirmRecall = nil } }), presenting: confirmRecall
        ) { p in
          Button("撤回", role: .destructive) {
            Task {
              guard let uid = accounts.state.active, !busy else { return }
              busy = true; defer { busy = false }
              do { try await recall.recall(p.bullet, cid: cid, author: uid); done("删除成功") }
              catch { done(error.localizedDescription) }
            }
          }
        }
        .piliSheet(item: $reporting, onDismiss: { inspector.pick = nil }) { p in
          if let id = p.bullet.entryID, let uid = accounts.state.active {
            BulletReportSheet(cid: cid, id: id, uid: uid, sender: p.bullet.sender) { done($0) }
          }
        }
      }
    }.onChange(of: cid) { _, _ in
      inspector.pick = nil
      reporting = nil
    }.onDisappear { inspector.pick = nil }
  }
  private func arrow(up: Bool) -> some View {
    Path { p in
      p.move(to: CGPoint(x: 0, y: up ? 6 : 0)); p.addLine(to: CGPoint(x: 6, y: up ? 0 : 6))
      p.addLine(to: CGPoint(x: 12, y: up ? 6 : 0)); p.closeSubpath()
    }.fill(.black.opacity(0.78)).frame(width: 12, height: 6)
  }
  private func icon(_ symbol: String, _ label: String, _ action: @escaping () -> Void) -> some View {
    Button { TouchFeedback.light(); action() } label: {
      Image(systemName: symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(.white)
        .frame(width: item, height: 38).contentShape(Rectangle())
    }.buttonStyle(.plain).accessibilityLabel(label)
  }
  @ViewBuilder private func likeItem(_ pick: BulletPick, cid: Int64) -> some View {
    let uid = accounts.state.active
    let liked = uid.flatMap { u in pick.bullet.entryID.map { likes.ids.contains(.init(uid: u, cid: cid, id: $0)) } } ?? false
    let n = likes.count(pick.bullet, cid: cid, owner: uid)
    icon(liked ? "hand.thumbsup.fill" : "hand.thumbsup", liked ? "取消点赞" : "点赞") {
      guard let uid, let id = pick.bullet.entryID, !busy else { done("请先登录"); return }
      Task {
        busy = true; defer { busy = false }
        do {
          let receipt = try await BiliAPI.shared.bulletLike(id: id, cid: cid, on: !liked, uid: uid)
          guard accounts.state.active == uid else { return }
          likes.record(.init(uid: uid, cid: cid, id: id), receipt: receipt, initial: pick.bullet.likes ?? 0)
          done(receipt.liked ? "点赞成功" : "取消点赞成功")
        } catch { done(error.localizedDescription) }
      }
    }
    .overlay(alignment: .topTrailing) {
      if n > 0 { Text("\(n)").font(.system(size: 10.5)).foregroundStyle(.white).offset(x: -4, y: 2) }
    }
  }
  private func done(_ message: String) {
    toast = message
    Task {
      try? await Task.sleep(for: .seconds(1.4))
      if toast == message { toast = nil; inspector.pick = nil }
    }
  }
}
