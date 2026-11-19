import SwiftUI
import UIKit

struct ReplySelection: View {
  let reply: Reply
  @Environment(\.dismiss) private var dismiss
  @State private var emotes = false
  @State private var pending: String?
  @State private var destination: Opening?
  @State private var issue: String?
  private struct Opening: Identifiable { let id = UUID(), text: String }
  var body: some View {
    PiliNavigationStack {
      VStack {
        if let notes = reply.content.emote, !notes.isEmpty {
          Picker("显示", selection: $emotes) {
            Text("正文").tag(false)
            Text("表情").tag(true)
          }.pickerStyle(.segmented).padding(.horizontal)
          if emotes {
            List(notes.keys.sorted(), id: \.self) { token in
              if let e = notes[token] {
                HStack(alignment: .top) {
                  if let u = e.url.flatMap(GalleryPicture.source) {
                    GalleryLink([.init(u)], index: 0) {
                      GalleryThumb(photo: .init(u)).frame(width: 46, height: 46)
                    }
                  }
                  ReplySelectedText(
                    text: [token, e.url].compactMap { $0 }.joined(separator: "\n"),
                    filter: { pending = $0 }, launch: { destination = Opening(text: $0) }
                  ).frame(minHeight: 60)
                }
              }
            }
          }
        }
        if !emotes {
          ReplySelectedText(
            text: reply.content.message, filter: { pending = $0 },
            launch: { destination = Opening(text: $0) }
          ).padding(.horizontal)
        }
      }
      .navigationTitle("自由复制")
      .toolbar { Button("完成") { dismiss() } }
      .confirmationDialog(
        "把所选文字加入评论过滤？",
        isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
        presenting: pending
      ) { word in
        Button("加入过滤") {
          do { try ReplyFilterRules.current().addingLiteral(word).save() } catch {
            issue = error.localizedDescription
          }
        }
      } message: {
        Text($0)
      }
      .alert("评论过滤", isPresented: Binding(get: { issue != nil }, set: { if !$0 { issue = nil } })) {
        Button("好") {}
      } message: {
        Text(issue ?? "")
      }
      .piliSheet(item: $destination) { v in
        PiliNavigationStack {
          Group {
            if let link = SharedLink.parse(v.text) {
              LinkDestination(item: link)
            } else if let u = ReplySelectedText.safeURL(v.text) {
              SitePage(url: u)
            } else {
              SearchView(keyword: v.text)
            }
          }
          .toolbar { Button("关闭") { destination = nil } }
        }
      }
    }
  }
}
private struct ReplySelectedText: UIViewRepresentable {
  let text: String, filter: (String) -> Void, launch: (String) -> Void
  static func safeURL(_ word: String) -> URL? {
    guard let u = URL(string: word), let s = u.scheme?.lowercased(), ["https", "http"].contains(s),
      u.host?.isEmpty == false, u.user == nil, u.password == nil
    else { return nil }
    return u
  }
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: ReplySelectedText
    init(_ parent: ReplySelectedText) { self.parent = parent }
    func textView(
      _ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]
    ) -> UIMenu? {
      let source = textView.text as NSString
      guard range.length > 0, range.location >= 0, range.location <= source.length,
        range.length <= source.length - range.location
      else { return UIMenu(children: suggestedActions) }
      let value = source.substring(with: range)
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { return UIMenu(children: suggestedActions) }
      let isLink = SharedLink.parse(trimmed) != nil || ReplySelectedText.safeURL(trimmed) != nil
      return UIMenu(
        children: suggestedActions + [
          UIAction(
            title: isLink ? "打开" : "站内搜索",
            image: UIImage(systemName: isLink ? "arrow.up.right" : "magnifyingglass")
          ) { [weak self] _ in self?.parent.launch(trimmed) },
          UIAction(title: "加入过滤", image: UIImage(systemName: "line.3.horizontal.decrease.circle")) {
            [weak self] _ in self?.parent.filter(value)
          },
        ])
    }
  }
  func makeCoordinator() -> Coordinator { .init(self) }
  func makeUIView(context: Context) -> UITextView {
    let v = UITextView()
    v.isEditable = false
    v.isSelectable = true
    v.delegate = context.coordinator
    v.backgroundColor = .clear
    v.adjustsFontForContentSizeCategory = true
    v.font = .preferredFont(forTextStyle: .body)
    return v
  }
  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.parent = self
    if view.text != text { view.text = text }
  }
}
