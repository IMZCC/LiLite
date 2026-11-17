import PiliWire
import SwiftUI

struct TranslatableReply: View {
  let reply: Reply, lines: Int, oid: Int64, type: Int, uid: String?
  @State private var translation: Reply.Content?
  @State private var override: Bool?
  @State private var loading = false
  @State private var issue: String?
  private var translated: Reply.Content? { translation ?? reply.initialTranslation }
  private var showing: Bool { (override ?? reply.showTranslation) && translated != nil }
  var body: some View {
    ReplyRichText(content: showing ? translated! : reply.content, maxLines: lines, lineSpacing: 4,
      textStyle: .callout)
      .id(showing)
    if reply.translateEnabled {
      Button {
        Task { await toggle() }
      } label: {
        Label(loading ? "正在翻译" : (showing ? "查看原文" : "翻译"), systemImage: "character.bubble")
      }.buttonStyle(.plain).foregroundStyle(showing ? Color.accentColor : Color.secondary)
        .font(.caption).disabled(loading)
      if let issue { Text(issue).font(.caption).foregroundStyle(.secondary) }
    }
  }
  @MainActor private func toggle() async {
    if showing {
      override = false
      return
    }
    if translated != nil {
      override = true
      return
    }
    guard !loading else { return }
    loading = true
    issue = nil
    defer { loading = false }
    do {
      let content = try await BiliAPI.shared.commentService(for: uid).translation(
        oid: oid, type: Int64(type), id: reply.id)
      try Task.checkCancellation()
      translation = Reply.Content(content)
      override = true
    } catch { if !Task.isCancelled { issue = error.localizedDescription } }
  }
}
struct ReplyReferencePicker: View {
  let oid: Int64, type: Int, uid: String, insert: (ReplyGateway.Reference) -> Void
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @State private var article = false
  @State private var visitedArticle = false
  @State private var input = ""
  @State private var keyword = ""
  var body: some View {
    VStack(spacing: 0) {
      ChipBar(items: [false, true], selection: $article, title: { $0 ? "专栏" : "视频" })
        .padding(.vertical, 6)
      ZStack {
        results(false).opacity(article ? 0 : 1).allowsHitTesting(!article).accessibilityHidden(
          article)
        if article || visitedArticle {
          results(true).opacity(article ? 1 : 0).allowsHitTesting(article).accessibilityHidden(
            !article)
        }
      }
    }.contextPushHost().navigationTitle("插入内容").searchable(text: $input, placement: .navigationBarDrawer(displayMode: .always), prompt: "视频或专栏")
      .onChange(of: article) { _, v in if v { visitedArticle = true } }
      .onChange(of: accounts.state.active) { _, v in if v != uid { dismiss() } }
      .onSubmit(of: .search) { keyword = input.trimmingCharacters(in: .whitespacesAndNewlines) }
      .onChange(of: input) { _, text in if text.isEmpty { keyword = "" } }
  }
  private func results(_ article: Bool) -> some View {
    PageList(empty: "没有匹配的内容") { offset in
      let r = try await BiliAPI.shared.commentService(for: uid).references(
        oid: oid, type: Int64(type), article: article, keyword: keyword,
        page: offset.flatMap(Int64.init) ?? 1)
      return Page(items: r.items, next: r.next.map(String.init))
    } row: { (r: ReplyGateway.Reference) in
      Button {
        guard accounts.state.active == uid else { return }
        insert(r)
        dismiss()
      } label: {
        HStack(spacing: 12) {
          SiteThumbnail(url: httpsURL(r.cover)) {
            $0.resizable().scaledToFill()
          } placeholder: {
            Color.clear
          }
          .frame(width: 82, height: 53).clipped()
          VStack(alignment: .leading) {
            Text(r.title).lineLimit(2)
            if let d = r.duration, let time = ReplyComposeAddress.timestamp(Double(d)) {
              Text(time).font(.caption2)
            }
            if !r.subtitle.isEmpty {
              Text(r.subtitle).piliFont(.caption).foregroundStyle(.secondary)
            }
          }
        }
      }.buttonStyle(.plain).contextMenu {
        if let u = GalleryPicture.source(r.cover) {
          ContextLink("查看或保存封面", systemImage: "photo") { NativeGallery([.init(u)]) }
        }
      }
    }.id("\(article):\(keyword):\(uid)")
  }

}
