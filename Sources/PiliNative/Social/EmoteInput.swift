import SwiftUI
import UIKit

struct SiteEmote: Decodable {
  struct Meta: Decodable { let size: Int?, alias: String? }
  let text: String?, url: String?, meta: Meta?
  var jump_url: String? = nil
  var jump_title: String? = nil
  var webp_url: String? = nil, gif_url: String? = nil
  var moving: URL? { [webp_url, gif_url].compactMap { $0.flatMap(httpsURL) }.first }
}
private struct EmotePack: Decodable {
  let id: Int?, text: String?, type: Int?, url: String?, emote: [SiteEmote]?
}
struct EmotePalette: View {
  let select: (String) -> Void
  /// Shown inside the comment composer: no title bar, and picking keeps the panel open.
  var inline = false
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @State private var packs: [EmotePack]?
  @State private var index = 0
  @State private var issue: String?
  @State private var retry = 0
  var body: some View {
    VStack {
      if let packs, !packs.isEmpty, packs.indices.contains(index) {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack {
            ForEach(Array(packs.enumerated()), id: \.offset) { i, p in
              Button {
                index = i
              } label: {
                HStack {
                  if let url = p.url.flatMap(httpsURL) {
                    RemoteArtwork(url: url) {
                      $0.resizable().scaledToFit()
                    } placeholder: {
                      Color.clear
                    }.frame(width: 25, height: 25)
                  }
                  Text(p.text ?? "表情包 \(i+1)").piliFont(.caption)
                }.padding(6).background(
                  index == i ? Color.accentColor.opacity(0.18) : Color.clear, in: Capsule())
              }
            }
          }.padding(.horizontal)
        }
        let pack = packs[index]
        let textOnly = pack.type == 4
        let width: CGFloat = textOnly ? 100 : pack.emote?.first?.meta?.size == 1 ? 44 : 62
        ScrollView {
          LazyVGrid(columns: [GridItem(.adaptive(minimum: width), spacing: 8)], spacing: 10) {
            ForEach(Array((pack.emote ?? []).enumerated()), id: \.offset) { _, e in
              if let token = e.text, !token.isEmpty {
                Button {
                  select(token)
                  if !inline { dismiss() }
                } label: {
                  if !textOnly, let url = e.url.flatMap(httpsURL) {
                    SiteThumbnail(url: url) { phase in
                      if let image = phase.image {
                        image.resizable().scaledToFit()
                      } else {
                        Text(token).piliFont(.caption2)
                      }
                    }.frame(height: width - 8)
                  } else {
                    Text(token).lineLimit(2)
                  }
                }.accessibilityLabel(e.meta?.alias ?? token).contextMenu {
                  Text(e.meta?.alias ?? token)
                  Button("插入") {
                    select(token)
                    if !inline { dismiss() }
                  }
                } preview: {
                  EmoteMenuPreview(url: e.url.flatMap(httpsURL), name: e.meta?.alias ?? token)
                }
              }
            }
          }.padding()
        }
      } else if let issue {
        ContentUnavailableView {
          Label("表情未载入", systemImage: "face.smiling")
        } description: {
          Text(issue)
        } actions: {
          Button("重试") { retry += 1 }
        }
      } else if packs != nil {
        ContentUnavailableView("暂无可用表情", systemImage: "face.smiling")
      } else {
        ProgressView()
      }
    }.modifier(EmotePaletteChrome(inline: inline)).task(
      id: "\(accounts.state.active ?? ""):\(retry)"
    ) {
      struct Response: Decodable { let packages: [EmotePack]? }
      packs = nil
      issue = nil
      index = 0
      do {
        let r = try await BiliAPI.shared.read(
          "/x/emote/user/panel/web", ["business": "reply", "web_location": "333.1245"],
          expectedAccount: accounts.state.active, as: Response.self)
        try Task.checkCancellation()
        packs = (r.packages ?? []).filter { !($0.emote ?? []).isEmpty }
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
}

private struct EmotePaletteChrome: ViewModifier {
  let inline: Bool
  @Environment(\.dismiss) private var dismiss
  func body(content: Content) -> some View {
    if inline {
      content
    } else {
      content.navigationTitle("表情").toolbar { Button("关闭") { dismiss() } }
    }
  }
}

struct CursorEditor: UIViewRepresentable {
  @Binding var text: String
  @Binding var selection: NSRange?
  let name: String, minimum: CGFloat, maximum: CGFloat
  var willEdit: ((NSRange, String) -> Void)? = nil
  var entityRanges: [NSRange]? = nil
  /// Two-way keyboard focus, for composers that swap the keyboard for their own panels.
  var focused: Binding<Bool>? = nil
  final class Coordinator: NSObject, UITextViewDelegate {
    var parent: CursorEditor
    var updating = false
    var coloredText: String?, coloredRanges: [NSRange]?
    /// The focus state last agreed between the binding and the text view. Only a change of the
    /// binding away from it moves the keyboard, so the two never fight over first responder.
    var agreedFocus: Bool?
    init(_ parent: CursorEditor) { self.parent = parent }
    func textView(_ v: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String)
      -> Bool
    {
      parent.willEdit?(range, text)
      return true
    }
    func textViewDidChange(_ v: UITextView) {
      if !updating {
        parent.text = v.text
        parent.selection = v.selectedRange
      }
    }
    func textViewDidChangeSelection(_ v: UITextView) {
      if !updating && v.isFirstResponder { parent.selection = v.selectedRange }
    }
    func textViewDidBeginEditing(_ v: UITextView) { report(true) }
    func textViewDidEndEditing(_ v: UITextView) { report(false) }
    private func report(_ focused: Bool) {
      agreedFocus = focused
      guard let binding = parent.focused, binding.wrappedValue != focused else { return }
      DispatchQueue.main.async { binding.wrappedValue = focused }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator(self) }
  /// Moves first responder on the next turn; a view still being presented has no window yet,
  /// so focusing retries briefly until it does.
  private static func apply(_ want: Bool, to v: UITextView, coordinator: Coordinator, tries: Int) {
    DispatchQueue.main.asyncAfter(deadline: .now() + (tries == 6 ? 0 : 0.06)) {
      guard coordinator.agreedFocus == want else { return }
      if want {
        if v.isFirstResponder { return }
        if v.window == nil {
          if tries > 0 { apply(want, to: v, coordinator: coordinator, tries: tries - 1) }
          return
        }
        v.becomeFirstResponder()
      } else if v.isFirstResponder {
        v.resignFirstResponder()
      }
    }
  }
  func makeUIView(context: Context) -> UITextView {
    let v = UITextView()
    v.delegate = context.coordinator
    v.font = UIFont.preferredFont(forTextStyle: .body)
    v.adjustsFontForContentSizeCategory = true
    v.backgroundColor = .clear
    v.accessibilityLabel = name
    v.textContainer.lineFragmentPadding = 0
    return v
  }
  func updateUIView(_ v: UITextView, context: Context) {
    context.coordinator.parent = self
    if let want = focused?.wrappedValue, want != context.coordinator.agreedFocus {
      context.coordinator.agreedFocus = want
      Self.apply(want, to: v, coordinator: context.coordinator, tries: 6)
    }
    guard v.markedTextRange == nil else { return }
    let replacing = v.text != text
    let decorating = entityRanges != nil && (context.coordinator.coloredRanges != entityRanges || context.coordinator.coloredText != text)
    guard replacing || decorating else { return }
    context.coordinator.updating = true
    defer { context.coordinator.updating = false }
    if replacing { v.text = text }
    let n = (text as NSString).length
    if decorating, let ranges = entityRanges {
      v.textStorage.beginEditing()
      v.textStorage.addAttribute(.foregroundColor, value: UIColor.label, range: .init(location: 0, length: n))
      for r in ranges where r.location >= 0 && r.location <= n && r.length > 0 && r.length <= n - r.location {
        v.textStorage.addAttribute(.foregroundColor, value: v.tintColor ?? UIColor.link, range: r)
      }
      v.textStorage.endEditing()
      v.typingAttributes[.foregroundColor] = UIColor.label
      context.coordinator.coloredRanges = ranges
      context.coordinator.coloredText = text
    }
    if replacing {
      if let range = selection, range.location >= 0, range.location <= n, range.length >= 0, range.length <= n - range.location {
        v.selectedRange = range
      } else { v.selectedRange = NSRange(location: n, length: 0) }
    }
  }
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    guard let w = proposal.width, w > 0 else { return nil }
    let h = uiView.sizeThatFits(.init(width: w, height: .greatestFiniteMagnitude)).height
    return .init(width: w, height: min(max(minimum, h), maximum))
  }
}
struct EmoteInput: View {
  @Binding var text: String
  let prompt: String
  var compact = false
  var cursor: Binding<NSRange?>? = nil
  var willEdit: ((NSRange, String) -> Void)? = nil
  var insertEmote: ((String) -> Void)? = nil
  var entityRanges: [NSRange]? = nil
  private var activeSelection: Binding<NSRange?> { cursor ?? $selection }
  @State private var selection: NSRange?
  @State private var palette = false
  var body: some View {
    HStack(alignment: .bottom) {
      ZStack(alignment: .topLeading) {
        if text.isEmpty {
          Text(prompt).foregroundStyle(.secondary).padding(.top, 8).allowsHitTesting(false)
            .accessibilityHidden(true)
        }
        CursorEditor(
          text: $text, selection: activeSelection, name: prompt, minimum: compact ? 37 : 96,
          maximum: compact ? 100 : 230, willEdit: willEdit, entityRanges: entityRanges)
      }
      Button {
        palette = true
      } label: {
        Image(systemName: "face.smiling").accessibilityLabel("添加表情")
      }.buttonStyle(.borderless).padding(.bottom, 7)
    }.piliSheet(isPresented: $palette) {
      PiliNavigationStack {
        EmotePalette { token in
          if let insertEmote {
            insertEmote(token)
            return
          }
          let s = text as NSString
          let selected = activeSelection.wrappedValue ?? NSRange(location: s.length, length: 0)
          let r =
            selected.location <= s.length && selected.length <= s.length - selected.location
            ? selected : NSRange(location: s.length, length: 0)
          let end = r.location + (token as NSString).length
          willEdit?(r, token)
          text = s.replacingCharacters(in: r, with: token)
          activeSelection.wrappedValue = NSRange(location: end, length: 0)
        }
      }.presentationDetents([.medium, .large])
    }
  }
}
