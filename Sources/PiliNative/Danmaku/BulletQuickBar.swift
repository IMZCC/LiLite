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
        Text("UP 主已关闭弹幕").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12)
      } else if let issue {
        Text(issue).font(.caption).foregroundStyle(.red).lineLimit(2).padding(.horizontal, 12)
      }
      HStack(spacing: 10) {
        // The original swaps the keyboard for the style panel in place.
        Button {
          TouchFeedback.light()
          styling.toggle()
          focused = !styling
        } label: {
          Image(systemName: "textformat").font(.system(size: 18, weight: .medium))
            .foregroundStyle(styling ? Color.accentColor : Color.secondary)
            .frame(width: 38, height: 38)
        }.buttonStyle(.plain).accessibilityLabel("弹幕样式")
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
      .padding(.horizontal, 12)
      if styling {
        Divider().opacity(0.5)
        BulletStylePanel().frame(minHeight: 240, alignment: .top)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
    }
    .padding(.top, 8).padding(.bottom, 8)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
    .animation(.snappy(duration: 0.25), value: styling)
    .onAppear { focused = true }
    .onChange(of: focused) { _, now in
      if now { styling = false }
      else if !styling && !busy { close() }
    }
    .onChange(of: accounts.state.active) { _, v in if v != uid { close() } }
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

/// Position, size and colour for new bullets, laid out like the original's send panel:
/// 弹幕字号 [小][标准], 弹幕样式 [滚动][顶部][底部], then the colour tiles with a custom tile last.
struct BulletStylePanel: View {
  @AppStorage("dm.writeMode") private var mode = 1
  @AppStorage("dm.writeSize") private var size = 25
  @AppStorage("dm.writeRGB") private var rgb = 0xffffff
  /// Bound to the 会员渐变色 tile when the account can use it (nil hides the tile).
  var gradient: Binding<Bool>? = nil
  @State private var picking = false
  private var custom: Binding<Color> {
    Binding(get: { BulletComposer.color(rgb) }, set: { color in
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
      func byte(_ x: CGFloat) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
      rgb = byte(r) << 16 | byte(g) << 8 | byte(b)
      gradient?.wrappedValue = false
    })
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 16) {
        Text("弹幕字号")
        HStack(spacing: 5) { choice("小", size == 18) { size = 18 }; choice("标准", size == 25) { size = 25 } }
      }
      HStack(spacing: 16) {
        Text("弹幕样式")
        HStack(spacing: 5) {
          choice("滚动", mode == 1) { mode = 1 }
          choice("顶部", mode == 5) { mode = 5 }
          choice("底部", mode == 4) { mode = 4 }
        }
      }
      HStack(alignment: .top, spacing: 16) {
        Text("弹幕颜色").padding(.top, 8)
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 38, maximum: 42), spacing: 4)], spacing: 4) {
          ForEach(BulletComposer.colors + (BulletComposer.colors.contains(rgb) ? [] : [rgb]), id: \.self) { value in
            tile(selected: value == rgb && gradient?.wrappedValue != true) {
              RoundedRectangle(cornerRadius: 6, style: .continuous).fill(BulletComposer.color(value))
                .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.secondary.opacity(0.25), lineWidth: 0.5) }
            } action: { rgb = value; gradient?.wrappedValue = false }
            .accessibilityLabel(String(format: "颜色 %06X", value))
          }
          if let gradient {
            tile(selected: gradient.wrappedValue) {
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(LinearGradient(colors: [Color(red: 0.87, green: 0.58, blue: 0.85), Color(red: 0.45, green: 0.7, blue: 0.92)],
                  startPoint: .leading, endPoint: .trailing))
                .overlay { RoundedRectangle(cornerRadius: 4).fill(.white).padding(5) }
            } action: { gradient.wrappedValue = true }
            .accessibilityLabel("会员渐变色")
          }
          ColorPicker(selection: custom, supportsOpacity: false) {
            Image(systemName: "pencil").font(.system(size: 18, weight: .semibold))
          }
          .labelsHidden()
          .frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
          .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
          .accessibilityLabel("自选颜色")
        }
      }
    }
    .font(.subheadline)
    .padding(.horizontal, 16).padding(.vertical, 12)
  }
  private func choice(_ title: String, _ on: Bool, _ pick: @escaping () -> Void) -> some View {
    Button { TouchFeedback.light(); pick() } label: {
      Text(title).foregroundStyle(on ? Color.accentColor : Color.secondary)
        .frame(maxWidth: .infinity).padding(.vertical, 5)
        .background(on ? Color.accentColor.opacity(0.14) : Color(uiColor: .tertiarySystemFill),
          in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }.buttonStyle(.plain)
  }
  private func tile<S: View>(selected: Bool, @ViewBuilder _ swatch: () -> S, action: @escaping () -> Void) -> some View {
    Button { TouchFeedback.light(); action() } label: {
      swatch().padding(2)
        .overlay { if selected { RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 2) } }
        .aspectRatio(1, contentMode: .fit)
    }.buttonStyle(.plain)
  }
}
