import SwiftUI
import UIKit

struct BulletComposer: View {
  let cid: Int64, bvid: String, time: Double, uid: String, posted: (Bullet) -> Void
  @Binding var draft: String
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("dm.writeMode") private var mode = 1
  @AppStorage("dm.writeSize") private var size = 25
  @AppStorage("dm.writeRGB") private var rgb = 0xffffff
  @ObservedObject private var availability=BulletAvailability.shared
  @State private var statusReady=false
  @State private var statusRetry=0
  @State private var vip = false
  @State private var gradient = false
  @State private var busy = false
  @State private var issue: String?
  static let colors = [
    0xffffff, 0xfe0302, 0xff7204, 0xffaa02, 0xffd302, 0xffff00, 0xa0ee00, 0x00cd00, 0x019899,
    0x4266be, 0x89d5ff, 0xcc0273, 0x222222, 0x9b9b9b,
  ]
  static func color(_ value: Int) -> Color {
    Color(
      red: Double(value >> 16 & 255) / 255, green: Double(value >> 8 & 255) / 255,
      blue: Double(value & 255) / 255)
  }
  private var selection: Binding<Color> {
    Binding(
      get: { Self.color(rgb) },
      set: { color in
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        func byte(_ x: CGFloat) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
        rgb = byte(r) << 16 | byte(g) << 8 | byte(b)
        gradient = false
      })
  }
  private var canSend: Bool {
    !busy && statusReady && !availability.closed(cid,owner:uid) && uid == accounts.state.active
      && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && draft.count <= 100
      && time.isFinite && time >= 0 && time < Double(Int64.max) / 1000
  }
  var body: some View {
    PiliNavigationStack {
      Form {
        Section {
          TextField("输入弹幕内容", text: $draft, axis: .vertical).lineLimit(2...5)
          Text(clockText(time) + " · " + String(draft.count) + "/100").font(.caption)
            .foregroundStyle(.secondary)
        }
        Section {
          Picker("位置", selection: $mode) {
            Text("滚动").tag(1)
            Text("顶部").tag(5)
            Text("底部").tag(4)
          }
          Picker("字号", selection: $size) {
            Text("小").tag(18)
            Text("标准").tag(25)
          }
        }
        Section("弹幕颜色") {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 35))]) {
            ForEach(Self.colors, id: \.self) { value in
              Button {
                rgb = value
                gradient = false
              } label: {
                Circle().fill(Self.color(value)).overlay {
                  Circle().stroke(.secondary, lineWidth: 0.5)
                }
                .frame(width: 28, height: 28).overlay {
                  if value == rgb && !gradient {
                    Image(systemName: "checkmark.circle.fill").symbolRenderingMode(.palette)
                      .foregroundStyle(.white, .black)
                  }
                }
              }.accessibilityLabel(String(format: "颜色 %06X", value)).buttonStyle(.borderless)
            }
          }
          ColorPicker("自选颜色", selection: selection, supportsOpacity: false)
          if vip { Toggle("会员渐变色", isOn: $gradient) }
        }
        if !statusReady,issue != nil{Button("重新读取发言状态"){statusRetry+=1}}
        if availability.closed(cid,owner:uid){Text("UP 主已关闭弹幕").foregroundStyle(.secondary)}
        if let issue { Text(issue).foregroundStyle(.secondary) }
      }.navigationTitle("发弹幕").toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
        ToolbarItem(placement: .confirmationAction) {
          Button("发送") { Task { await send() } }.disabled(!canSend)
        }
      }.disabled(busy)
    }.interactiveDismissDisabled(busy).task(id:"\(uid):\(cid):\(statusRetry)"){
      statusReady=false
      guard time.isFinite,time>=0,time<=31_536_000 else{return}
      if availability.status(cid,owner:uid)==nil{
        do{_=try await BiliAPI.shared.commentPage(cid:cid,aid:ArchiveNumber.av(bvid),index:1+Int(time/360),expectedAccount:uid)}
        catch{if !Task.isCancelled{issue=error.localizedDescription};return}
      }
      guard !Task.isCancelled,accounts.state.active==uid else{return}
      statusReady=true;issue=nil
    }.task(id: uid) {
      struct Info: Decodable { let vipStatus: Int? }
      vip = false
      gradient = false
      if let r = try? await BiliAPI.shared.read(
        "/x/web-interface/nav", [:], expectedAccount: uid, as: Info.self),
        r.vipStatus == 1, !Task.isCancelled, accounts.state.active == uid
      {
        vip = true
      }
    }.onChange(of: accounts.state.active) { _, v in if v != uid { dismiss() } }
  }
  @MainActor private func send() async {
    guard canSend, [1, 4, 5].contains(mode), [18, 25].contains(size), (0...0xffffff).contains(rgb)
    else { return }
    TouchFeedback.light()
    busy = true
    defer { busy = false }
    issue = nil
    let color = vip && gradient ? 0xffffff : rgb
    let text = draft
    let mode = self.mode
    let size = self.size
    var fields = [
      "type": "1", "oid": String(cid), "bvid": bvid, "msg": text,
      "progress": String(Int64(time * 1000)), "mode": String(mode), "color": String(color),
      "fontsize": String(size), "pool": "0",
      "rnd": String(Int64(Date().timeIntervalSince1970 * 1_000_000)),
    ]
    if vip && gradient { fields["colorful"] = String(Bullet.vipGradient) }
    do {
      let data = try await BiliAPI.shared.submitResponse(
        "/x/v2/dm/post", fields, expectedAccount: uid)
      struct Response: Decodable {
        struct Entry: Decodable { let dmid: ServiceID?, dmid_str: ServiceID? }
        let data: Entry?
      }
      let ack = try? JSONDecoder().decode(Response.self, from: data).data
      guard accounts.state.active == uid else {
        dismiss()
        return
      }
      BulletRecall.shared.posted(ack?.dmid?.number ?? ack?.dmid_str?.number, cid: cid, author: uid)
      posted(
        .init(
          time: time, mode: mode, rgb: color, text: text, fontSize: Double(size),
          sender: DanmakuStyle.senderHash(uid), entryID: ack?.dmid?.number ?? ack?.dmid_str?.number,
          colorType: vip && gradient ? Bullet.vipGradient : nil))
      draft = ""
      dismiss()
    } catch { issue = error.localizedDescription }
  }
}
struct EpisodeBulletAction: View {
  let cid: Int64, bvid: String, model: PlayerModel
  /// As a player header glyph (fullscreen "发弹幕") instead of a labelled row.
  var glyph = false
  @EnvironmentObject private var accounts: AccountContext
  @State private var writing = false
  @State private var at = 0.0
  @State private var text = ""
  var body: some View {
    Button {
      at = model.seconds
      writing = true
    } label: {
      if glyph {
        PlayerGlyph(symbol: "square.and.pencil")
      } else {
        Label("发弹幕", systemImage: "text.bubble")
      }
    }
    .accessibilityLabel("发弹幕")
    .disabled(accounts.state.active == nil)
    .piliSheet(isPresented: $writing) {
      if let uid = accounts.state.active {
        BulletComposer(
          cid: cid, bvid: bvid, time: at, uid: uid, posted: { model.didPost($0, cid: cid) },
          draft: $text)
      }
    }.onChange(of: accounts.state.active) { _, _ in
      writing = false
      text = ""
    }
  }
}
