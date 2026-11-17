import SwiftUI

/// A one-line bullet composer that rides on top of the keyboard, as in the original client.
/// Style options live behind the palette button in a compact sheet.
struct BulletQuickBar: View {
  let cid: Int64, bvid: String, uid: String
  let time: () -> Double
  let posted: (Bullet) -> Void
  let close: () -> Void
  @Binding var draft: String
  @EnvironmentObject private var accounts: AccountContext
  @AppStorage("dm.writeMode") private var mode = 1
  @AppStorage("dm.writeSize") private var size = 25
  @AppStorage("dm.writeRGB") private var rgb = 0xffffff
  @ObservedObject private var availability = BulletAvailability.shared
  @FocusState private var focused: Bool
  @State private var busy = false
  @State private var issue: String?
  @State private var styling = false
  private var trimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var canSend: Bool {
    !busy && !trimmed.isEmpty && draft.count <= 100 && uid == accounts.state.active
      && !availability.closed(cid, owner: uid)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if availability.closed(cid, owner: uid) {
        Text("UP 主已关闭弹幕").font(.caption).foregroundStyle(.secondary)
      } else if let issue {
        Text(issue).font(.caption).foregroundStyle(.red).lineLimit(2)
      }
      HStack(spacing: 10) {
        Button { styling = true } label: {
          Image(systemName: "paintpalette").font(.system(size: 17, weight: .medium))
            .foregroundStyle(BulletComposer.color(rgb) == .white ? Color.primary : BulletComposer.color(rgb))
            .frame(width: 38, height: 38)
        }.buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("弹幕样式")
        TextField("发个友善的弹幕见证当下", text: $draft)
          .focused($focused).submitLabel(.send).onSubmit { Task { await send() } }
          .padding(.horizontal, 14).frame(height: 40)
          .background(Color(uiColor: .secondarySystemBackground), in: Capsule())
          .overlay(alignment: .trailing) {
            if draft.count > 80 {
              Text("\(draft.count)/100").font(.caption2).monospacedDigit()
                .foregroundStyle(draft.count > 100 ? .red : .secondary).padding(.trailing, 12)
            }
          }
        Button { Task { await send() } } label: {
          Group {
            if busy { ProgressView().tint(.white) }
            else { Image(systemName: "arrow.up").font(.system(size: 16, weight: .bold)) }
          }
          .foregroundStyle(.white).frame(width: 38, height: 38)
          .background(canSend ? Color.accentColor : Color.secondary.opacity(0.4), in: Circle())
        }.buttonStyle(.plain).disabled(!canSend).accessibilityLabel("发送弹幕")
          .animation(.snappy(duration: 0.2), value: canSend)
      }
    }
    .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 8)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .onAppear { focused = true }
    .onChange(of: focused) { _, now in
      if !now && !styling && !busy { close() }
    }
    .onChange(of: accounts.state.active) { _, v in if v != uid { close() } }
    .piliSheet(isPresented: $styling, onDismiss: { focused = true }) {
      BulletStyleSheet().presentationDetents([.medium, .large]).presentationDragIndicator(.visible)
    }
    .task(id: "\(uid):\(cid)") {
      // Learn whether bullets are closed for this part before the first send.
      guard availability.status(cid, owner: uid) == nil else { return }
      let t = time()
      guard t.isFinite, t >= 0 else { return }
      _ = try? await BiliAPI.shared.commentPage(
        cid: cid, aid: ArchiveNumber.av(bvid), index: 1 + Int(t / 360), expectedAccount: uid)
    }
  }
  @MainActor private func send() async {
    let at = time()
    guard canSend, at.isFinite, at >= 0, [1, 4, 5].contains(mode), [18, 25].contains(size),
      (0...0xffffff).contains(rgb)
    else { return }
    TouchFeedback.light()
    busy = true
    defer { busy = false }
    issue = nil
    let text = draft
    let fields = [
      "type": "1", "oid": String(cid), "bvid": bvid, "msg": text,
      "progress": String(Int64(at * 1000)), "mode": String(mode), "color": String(rgb),
      "fontsize": String(size), "pool": "0",
      "rnd": String(Int64(Date().timeIntervalSince1970 * 1_000_000)),
    ]
    do {
      let data = try await BiliAPI.shared.submitResponse("/x/v2/dm/post", fields, expectedAccount: uid)
      struct Response: Decodable {
        struct Entry: Decodable { let dmid: ServiceID?, dmid_str: ServiceID? }
        let data: Entry?
      }
      let ack = try? JSONDecoder().decode(Response.self, from: data).data
      guard accounts.state.active == uid else { close(); return }
      let id = ack?.dmid?.number ?? ack?.dmid_str?.number
      BulletRecall.shared.posted(id, cid: cid, author: uid)
      posted(.init(
        time: at, mode: mode, rgb: rgb, text: text, fontSize: Double(size),
        sender: DanmakuStyle.senderHash(uid), entryID: id, colorType: nil))
      draft = ""
      close()
    } catch {
      issue = error.localizedDescription
    }
  }
}

/// Position, size and colour for new bullets.
struct BulletStyleSheet: View {
  @AppStorage("dm.writeMode") private var mode = 1
  @AppStorage("dm.writeSize") private var size = 25
  @AppStorage("dm.writeRGB") private var rgb = 0xffffff
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    PiliNavigationStack {
      Form {
        Section {
          Picker("位置", selection: $mode) {
            Text("滚动").tag(1)
            Text("顶部").tag(5)
            Text("底部").tag(4)
          }.pickerStyle(.segmented)
          Picker("字号", selection: $size) {
            Text("小").tag(18)
            Text("标准").tag(25)
          }.pickerStyle(.segmented)
        }
        Section("颜色") {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: 38), spacing: 12)], spacing: 12) {
            ForEach(BulletComposer.colors, id: \.self) { value in
              Button { TouchFeedback.light(); rgb = value } label: {
                Circle().fill(BulletComposer.color(value))
                  .overlay { Circle().strokeBorder(.secondary.opacity(0.4), lineWidth: 0.5) }
                  .overlay {
                    if value == rgb {
                      Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                        .foregroundStyle(value == 0xffffff || value == 0xffff00 || value == 0xffd302 ? Color.black : Color.white)
                    }
                  }
                  .frame(width: 32, height: 32)
              }.buttonStyle(.plain).accessibilityLabel(String(format: "颜色 %06X", value))
            }
          }.padding(.vertical, 6)
        }
      }
      .navigationTitle("弹幕样式").navigationBarTitleDisplayMode(.inline)
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
    }
  }
}
