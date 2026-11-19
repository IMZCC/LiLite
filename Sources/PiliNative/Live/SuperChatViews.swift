import ImageIO
import Photos
import SwiftUI
import UniformTypeIdentifiers

private func scColor(_ value: String, fallback: Color) -> Color {
  guard value.hasPrefix("#"), value.count == 7, let n = UInt32(value.dropFirst(), radix: 16) else {
    return fallback
  }
  return Color(
    red: Double(n >> 16) / 255, green: Double(n >> 8 & 255) / 255, blue: Double(n & 255) / 255)
}
private func artURL(_ raw: String?) -> URL? {
  guard let raw, let url = httpsURL(raw), let host = url.host?.lowercased(),
    ["hdslb.com", "biliimg.com", "bilibili.com"].contains(where: {
      host == $0 || host.hasSuffix("." + $0)
    })
  else { return nil }
  return url
}
private actor SuperChatArt {
  static let shared = SuperChatArt()
  func image(_ raw: String?) async -> UIImage? {
    guard let u = artURL(raw) else { return nil }
    return try? await ArtworkStore.shared.image(u, pixels: 700, maximum: 4 * ArtworkStore.mib)
  }
}
private struct SCArtView: View {
  let raw: String?, fixed: UIImage?
  @State private var loaded: UIImage?
  var body: some View {
    Group {
      if let image = fixed ?? loaded {
        Image(uiImage: image).resizable().scaledToFit()
      } else {
        Color.clear
      }
    }
    .task(id: raw) {
      loaded = nil
      if fixed == nil {
        let i = await SuperChatArt.shared.image(raw)
        if !Task.isCancelled { loaded = i }
      }
    }
  }
}
private struct SCCard: View {
  let row: SuperChatMessage, now: Int64, medal: Bool
  var avatar: UIImage? = nil, frame: UIImage? = nil, bg: UIImage? = nil
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        ZStack {
          Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.secondary)
          SCArtView(raw: row.face, fixed: avatar).clipShape(Circle())
          if row.frame?.isEmpty == false {
            SCArtView(raw: row.frame, fixed: frame).scaleEffect(1.22)
          }
        }.frame(width: 32, height: 32)
        VStack(alignment: .leading) {
          Text(row.name).font(.subheadline.bold()).foregroundStyle(
            scColor(row.nameColor, fallback: .black)
          ).lineLimit(1)
          if medal, let name = row.medal {
            Text(name + (row.medalLevel.map { " · \($0)" } ?? "")).font(.caption2).foregroundStyle(
              .black.opacity(0.7))
          }
        }
        Spacer()
        Text("¥\(row.price)").bold().foregroundStyle(scColor(row.priceColor, fallback: .blue))
      }.padding(8).background(alignment: .trailing) { SCArtView(raw: row.background, fixed: bg) }
        .background(scColor(row.topColor, fallback: .white))
      VStack(alignment: .leading, spacing: 4) {
        Text(row.text).font(.body)
        Text(now >= row.end ? "已结束" : "剩余 \(max(0,row.end-now)) 秒").font(
          .caption2.monospacedDigit())
      }.frame(maxWidth: .infinity, alignment: .leading).padding(8).foregroundStyle(
        scColor(row.textColor, fallback: .white)
      ).background(scColor(row.bottomColor, fallback: .blue))
    }.clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}
struct SuperChatOverlay: View {
  @ObservedObject var chat: LiveChat
  let enabled: Bool, shield: LiveShield?
  @AppStorage("live.paidOpacity") private var opacity = 1.0
  @AppStorage("live.paidScale") private var scale = 1.0
  @AppStorage("live.paidWidth") private var width = 255.0
  @AppStorage("live.medal") private var medal = true
  var body: some View {
    if enabled, chat.paid.featured != nil {
      TimelineView(.periodic(from: .now, by: 1)) { t in
        let now = Int64(t.date.timeIntervalSince1970)
        if let s = chat.paid.overlay(at: now),
          shield?.hides(.init(name: s.name, text: s.text, uid: s.uid)) != true
        {
          GeometryReader { g in
            SCCard(row: s, now: now, medal: medal).frame(
              width: min(width, max(25, g.size.width - 50))
            )
            .scaleEffect(scale, anchor: .bottomLeading).opacity(opacity).padding(25)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
          }
        }
      }.allowsHitTesting(false)
    }
  }
}
struct SuperChatSettings: View {
  @AppStorage("live.paidMode") private var mode = 0
  @AppStorage("live.paidFullscreen") private var enabled = true
  @AppStorage("live.paidOpacity") private var opacity = 1.0
  @AppStorage("live.paidScale") private var scale = 1.0
  @AppStorage("live.paidWidth") private var width = 255.0
  @AppStorage("live.medal") private var medal = true
  private let preview = try? JSONDecoder().decode(
    SuperChatMessage.self,
    from: Data(
      #"{"id":1,"uid":1,"price":30,"start_time":0,"end_time":60,"message":"谢谢分享！","user_info":{"uname":"留言预览"}}"#
        .utf8))
  var body: some View {
    Form {
      Picker("醒目留言", selection: $mode) {
        ForEach(SuperChatDisplay.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
      }.settingAnchor("SuperChatSettings/醒目留言")
      Toggle("显示粉丝勋章", isOn: $medal).settingAnchor("SuperChatSettings/显示粉丝勋章")
      Section("全屏播放") {
        Toggle("显示新收到的留言", isOn: $enabled).settingAnchor("SuperChatSettings/显示新收到的留言")
        if enabled {
          if let preview {
            SCCard(row: preview, now: 0, medal: false).frame(maxWidth: min(width, 600)).scaleEffect(
              scale, anchor: .leading
            ).opacity(opacity)
          }
          SettingSlider(title: "不透明度", value: $opacity, range: 0.1...1).settingAnchor("SuperChatSettings/不透明度")
          SettingSlider(title: "缩放", value: $scale, range: 0.1...1).settingAnchor("SuperChatSettings/缩放")
          SettingSlider(title: "宽度", value: $width, range: 25...max(640, width), step: 1) { "\(Int($0)) 点" }.settingAnchor("SuperChatSettings/宽度")
        }
        Button("还原全屏设置") {
          enabled = true
          opacity = 1
          scale = 1
          width = 255
        }.settingAnchor("SuperChatSettings/还原全屏设置")
      }.settingAnchor("SuperChatSettings/全屏播放")
    }.navigationTitle("醒目留言设置")
  }
}
struct SuperChatFeed: View {
  @ObservedObject var chat: LiveChat
  let room: Int64
  @Binding var shield: LiveShield?
  @AppStorage("live.paidMode") private var mode = 0
  @AppStorage("live.medal") private var medal = true
  @EnvironmentObject private var accounts: AccountContext
  @State private var selected: LiveActionSelection?
  @State private var note: String?
  var body: some View {
    TimelineView(.periodic(from: .now, by: 1)) { tick in
      let now = Int64(tick.date.timeIntervalSince1970)
      let rows = chat.paid.visible(mode: SuperChatDisplay(rawValue: mode) ?? .current, at: now)
        .filter { shield?.hides(.init(name: $0.name, text: $0.text, uid: $0.uid)) != true }
      List {
        if let issue = chat.paidIssue {
          Text(issue)
          Button("重试") { chat.loadPaid() }
        }
        if let note { Text(note) }
        if rows.isEmpty { ContentUnavailableView("暂无醒目留言", systemImage: "text.bubble") }
        ForEach(rows) { s in
          VStack(alignment: .leading, spacing: 5) {
            SCCard(row: s, now: now, medal: medal)
            HStack {
              NavigationLink("查看发送者") { DeferredPage { CreatorSpace(mid: s.uid, name: s.name) } }
              Spacer()
              Menu {
                Button("复制留言信息") {
                  do {
                    let d = try s.copyInfo(room: room)
                    UIPasteboard.general.setItems(
                      [[UTType.utf8PlainText.identifier: String(decoding: d, as: UTF8.self)]],
                      options: [.localOnly: true])
                    note = "已复制"
                  } catch { note = error.localizedDescription }
                }
                Button("保存为图片") { Task { await save(s, now: now) } }
                Button("留言操作") {
                  selected = .init(
                    line: .init(
                      name: s.name, text: s.text, highlight: true, uid: s.uid, paidID: s.id,
                      room: room),
                    paid: s, room: room, owner: accounts.state.active)
                }
              } label: {
                Image(systemName: "ellipsis.circle").accessibilityLabel("留言操作")
              }
            }.font(.caption)
          }
        }
      }
    }.navigationTitle("醒目留言").piliSheet(item: $selected) { selection in
      LiveChatActions(selection: selection, shield: $shield)
    }.onChange(of: accounts.state.active) { _, _ in selected = nil }
      .onChange(of: room) { _, _ in selected = nil }
  }
  @MainActor private func save(_ s: SuperChatMessage, now: Int64) async {
    let access = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    guard access == .authorized || access == .limited else {
      note = "请允许保存到照片"
      return
    }
    async let a = SuperChatArt.shared.image(s.face)
    async let f = SuperChatArt.shared.image(s.frame)
    async let b = SuperChatArt.shared.image(s.background)
    let card = await SCCard(row: s, now: now, medal: medal, avatar: a, frame: f, bg: b)
    let renderer = ImageRenderer(content: card.frame(width: 350).padding(10).background(.white))
    renderer.scale = 2
    guard let image = renderer.uiImage else {
      note = "未能生成图片"
      return
    }
    do {
      try await PHPhotoLibrary.shared().performChanges {
        PHAssetChangeRequest.creationRequestForAsset(from: image)
      }
      note = "已存入照片"
    } catch { note = error.localizedDescription }
  }
}
