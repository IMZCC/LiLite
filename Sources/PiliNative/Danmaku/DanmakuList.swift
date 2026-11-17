import SwiftUI

struct DanmakuList: View {
  let cid: Int64, aid: Int64?, duration: Double, current: Double, seek: (Double) -> Void
  let snapshot: (() -> [Bullet])?
  @State private var onScreen: Bool
  @EnvironmentObject private var accounts: AccountContext
  @State private var rows: [Bullet] = []
  @ObservedObject private var likes = BulletLikes.shared
  @ObservedObject private var recall = BulletRecall.shared
  @State private var selected: BulletPick?
  @State private var page = 1
  @State private var search = ""
  @State private var retry = 0
  @State private var loading = true
  @State private var issue: String?
  @Environment(\.dismiss) private var dismiss
  init(
    cid: Int64, aid: Int64?, duration: Double, current: Double, seek: @escaping (Double) -> Void,
    snapshot: (() -> [Bullet])? = nil
  ) {
    self.snapshot = snapshot
    _onScreen = State(initialValue: snapshot != nil)
    self.cid = cid
    self.aid = aid
    self.duration = duration
    self.current = current
    self.seek = seek
    _page = State(initialValue: 1 + Int(max(0, current)) / 360)
  }
  private var pages: Int { max(page, max(1, Int(ceil(max(0, duration) / 360)))) }
  var body: some View {
    List {
      if snapshot != nil {
        ChipBar(items: [true, false], selection: $onScreen, title: { $0 ? "屏幕上" : "时间段" })
          .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
      }
      if !onScreen {
        Picker("时间段", selection: $page) {
          ForEach(1...pages, id: \.self) { n in
            Text(
              "\(clockText(Double(n-1)*360)) – \(clockText(duration>0 ? min(duration,Double(n)*360):Double(n)*360))"
            ).tag(n)
          }
        }
      }
      if loading {
        ProgressView()
      } else if let issue {
        Text(issue)
        Button("重试") { retry += 1 }
      } else {
        let matches = rows.filter {
          recall.visible($0, cid: cid)
            && (search.isEmpty || $0.text.localizedStandardContains(search))
        }
        if matches.isEmpty { Text("没有找到弹幕").foregroundStyle(.secondary) }
        ForEach(Array(matches.enumerated()), id: \.offset) { _, b in
          Button {
            seek(b.time)
            dismiss()
          } label: {
            HStack(alignment: .top) {
              Text(clockText(b.time)).font(.caption.monospacedDigit())
              Text(b.text)
              Spacer()
              let n = likes.count(b, cid: cid, owner: accounts.state.active)
              if n > 0 {
                Label(String(n), systemImage: "hand.thumbsup").piliFont(.caption)
              }
            }
          }
          .contextMenu {
            Button("弹幕操作") { selected = BulletPick(bullet: b, rect: .zero, text: b.text) }
            Button("复制内容") { UIPasteboard.general.string = b.text }
            if let sender = b.sender, !sender.isEmpty {
              Button("屏蔽该发送者") {
                var s = DanmakuStyle.decode(
                  UserDefaults.standard.data(forKey: DanmakuStyle.key) ?? Data())
                let stored = Set(s.senders.split(whereSeparator: \.isNewline).map(String.init))
                s.senders = stored.union([sender]).sorted().joined(separator: "\n")
                do { try s.save() } catch { issue = error.localizedDescription }
              }
            }
          }
        }
      }
    }.piliSheet(item: $selected) { p in
      PiliNavigationStack {
        BulletActionPanel(cid: cid, bullet: p.bullet).toolbar { Button("完成") { selected = nil } }
      }
    }.navigationTitle("弹幕列表").searchable(text: $search, prompt: "搜索本段弹幕")
      .toolbar {
        Button {
          retry += 1
        } label: {
          Label("刷新弹幕", systemImage: "arrow.clockwise")
        }
      }
      .task(id: "\(cid):\(page):\(retry):\(onScreen):\(accounts.state.active ?? "")") {
        loading = true
        rows = []
        issue = nil
        do {
          let r =
            if onScreen { snapshot?() ?? [] } else {
              try await BiliAPI.shared.commentSegment(
                cid: cid, aid: aid, index: page, expectedAccount: accounts.state.active ?? "")
            }
          try Task.checkCancellation()
          rows = r
        } catch { if !Task.isCancelled { issue = error.localizedDescription } }
        if !Task.isCancelled { loading = false }
      }
  }
}
