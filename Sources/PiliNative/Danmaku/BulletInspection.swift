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
struct BulletActionPanel: View {
  let cid: Int64, bullet: Bullet
  @EnvironmentObject private var accounts: AccountContext
  @ObservedObject private var likes = BulletLikes.shared
  @ObservedObject private var recall = BulletRecall.shared
  @State private var confirmRecall: String?
  @Environment(\.dismiss) private var dismiss
  private var liked: Bool {
    guard let uid = accounts.state.active, let id = bullet.entryID else { return false }
    return likes.ids.contains(.init(uid: uid, cid: cid, id: id))
  }
  @State private var busy = false
  @State private var report = false
  @State private var result: String?
  var body: some View {
    Form {
      Section(clockText(bullet.time)) {
        Text(bullet.special?.text ?? bullet.text).textSelection(.enabled)
      }
      Section {
        Button("复制内容") {
          UIPasteboard.general.string = bullet.special?.text ?? bullet.text
          result = "已复制"
        }
        if let id = bullet.entryID, id > 0 {
          Button(liked ? "取消点赞" : "点赞") {
            Task {
              guard let uid = accounts.state.active, !busy else {
                result = "请先登录"
                return
              }
              busy = true
              defer { busy = false }
              do {
                let desired = !liked
                let receipt=try await BiliAPI.shared.bulletLike(id:id,cid:cid,on:desired,uid:uid)
                guard accounts.state.active==uid else{return}
                likes.record(.init(uid:uid,cid:cid,id:id),receipt:receipt,initial:bullet.likes ?? 0)
                result=receipt.liked ? "已点赞":"已取消点赞"
              } catch { result = error.localizedDescription }
            }
          }.disabled(busy)
          if let uid = accounts.state.active, recall.owns(bullet, cid: cid, author: uid) {
            if recall.visible(bullet, cid: cid) {
              Button("撤回弹幕", role: .destructive) { confirmRecall = uid }.disabled(busy)
            } else {
              Text("已撤回").foregroundStyle(.secondary)
            }
          } else {
            Button("举报弹幕") {
              if accounts.state.active == nil { result = "请先登录" } else { report = true }
            }
          }
        }
        if let sender = bullet.sender, !sender.isEmpty {
          if let uid = accounts.state.active {
            Button("在账号中屏蔽该发送者") {
              Task {
                guard !busy else { return }
                busy = true
                defer { busy = false }
                do {
                  try await AccountBulletRules.shared.update(uid, type: 2, input: sender, senderHash: true)
                  result = "已屏蔽"
                } catch { result = error.localizedDescription }
              }
            }.disabled(busy)
          }
          Button("在本机屏蔽该发送者") {
            do {
              var s = DanmakuStyle.decode(
                UserDefaults.standard.data(forKey: DanmakuStyle.key) ?? Data())
              s.senders = Set(s.senders.split(whereSeparator: \.isNewline).map(String.init)).union([
                sender
              ]).sorted().joined(separator: "\n")
              try s.save()
              result = "已屏蔽"
            } catch { result = error.localizedDescription }
          }
        }
      }
      if let result { Text(result) }
    }.navigationTitle("弹幕")
      .confirmationDialog(
        "撤回自己发送的这条弹幕？",
        isPresented: Binding(
          get: { confirmRecall != nil }, set: { if !$0 { confirmRecall = nil } }),
        presenting: confirmRecall
      ) { uid in
        Button("撤回", role: .destructive) {
          Task {
            guard !busy, accounts.state.active == uid else { return }
            busy = true
            defer { busy = false }
            do {
              try await recall.recall(bullet, cid: cid, author: uid)
              dismiss()
            } catch { result = error.localizedDescription }
          }
        }
      }.piliSheet(isPresented: $report) {
        if let id = bullet.entryID, let uid = accounts.state.active {
          BulletReportSheet(cid:cid,id:id,uid:uid,sender:bullet.sender){result=$0}
        }
      }
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
private struct BulletReportSheet: View {
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
  var body: some View {
    PiliNavigationStack {
      Form {
        Picker("举报原因", selection: $reason) {
          ForEach(reasons.keys.sorted(), id: \.self) { k in Text(reasons[k] ?? "").tag(k) }
        }
        if reason == 11 { TextField("举报说明", text: $bodyText, axis: .vertical) }
        if sender?.isEmpty==false{Toggle("同时屏蔽发送者",isOn:$block)}
        if let issue { Text(issue) }
        Button("提交举报", role: .destructive) {
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
      }.navigationTitle("举报弹幕").toolbar { Button("取消") { dismiss() } }
    }
  }
}
struct PinnedBullet: View {
  @ObservedObject var inspector: BulletInspector
  let cid: Int64?
  var duration = 0.0
  var seek: ((Double) -> Void)? = nil
  @State private var detail: BulletPick?
  var body: some View {
    GeometryReader { geo in
      if let pick = inspector.pick, let cid {
        let w = min(240, max(1, geo.size.width - 16))
        VStack(alignment: .leading, spacing: 4) {
          Text(pick.text).lineLimit(2).bold().foregroundStyle(.white)
          HStack {
            if let seek, let t = BulletTrackFrame.timeLink(pick.text, duration: duration) {
              Button(clockText(t)) {
                seek(t)
                inspector.pick = nil
              }.foregroundStyle(.white)
            }
            Button("操作") { detail = pick }.foregroundStyle(.white)
            Button("复制") {
              UIPasteboard.general.string = pick.text
              inspector.pick = nil
            }.foregroundStyle(.white)
            Spacer()
            Button {
              inspector.pick = nil
            } label: {
              Image(systemName: "xmark").foregroundStyle(.white)
            }.accessibilityLabel("关闭")
          }
        }.font(.caption).padding(8).frame(width: w).background(
          .black.opacity(0.83), in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .position(
          x: min(max(w / 2 + 4, pick.rect.midX), geo.size.width - w / 2 - 4),
          y: min(max(34, pick.rect.midY), max(34, geo.size.height - 34))
        )
        .piliSheet(item: $detail, onDismiss: { inspector.pick = nil }) { item in
          PiliNavigationStack {
            BulletActionPanel(cid: cid, bullet: item.bullet).toolbar {
              Button("完成") { detail = nil }
            }
          }
        }
      }
    }.onChange(of: cid) { _, _ in
      inspector.pick = nil
      detail = nil
    }.onDisappear { inspector.pick = nil }
  }
}
