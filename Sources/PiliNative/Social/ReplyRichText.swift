import ImageIO
import SwiftUI

@MainActor private final class ReplyEmoteImages {
  static let shared = ReplyEmoteImages()
  func image(_ raw: String) async -> UIImage? {
    guard let url = httpsURL(raw), let host = url.host?.lowercased(),
      ["hdslb.com", "biliimg.com", "bilibili.com"].contains(where: {
        host == $0 || host.hasSuffix("." + $0)
      })
    else { return nil }
    return try? await ArtworkStore.shared.image(url, pixels: 128, maximum: 3 * ArtworkStore.mib)
  }
}
struct ReplyRichText: View {
  private let origin: InlineDocument, reply: Reply.Content?
  @AppStorage("reply.wordSearch") private var wordSearch = false
  @Environment(\.replyPlayback) private var playback
  var maxLines: Int, permitsPreview: Bool, dynamicID: String
  var textStyle: UIFont.TextStyle = .body
  /// Whether a clipped text offers an inline "展开" control (comment bodies) or simply truncates
  /// (previews, where tapping opens the thread instead).
  var expandable = true
  /// Extra spacing between lines, in points; comments read better a little looser.
  var lineSpacing: CGFloat = 0
  init(content: Reply.Content, maxLines: Int = 0, expandable: Bool = true, lineSpacing: CGFloat = 0,
    textStyle: UIFont.TextStyle = .body) {
    origin = InlineDocument(text: content.message)
    reply = content
    self.maxLines = maxLines
    permitsPreview = true
    dynamicID = "0"
    self.expandable = expandable
    self.lineSpacing = lineSpacing
    self.textStyle = textStyle
  }
  init(
    nodes: [RichNode], maxLines: Int = 0, permitsPreview: Bool = true, dynamicID: String = "0",
    textStyle: UIFont.TextStyle = .body
  ) {
    origin = InlineDocument(nodes: nodes)
    reply = nil
    self.maxLines = maxLines
    self.permitsPreview = permitsPreview
    self.dynamicID = dynamicID
    self.textStyle = textStyle
  }
  @AppStorage("emote.preview") private var preview = false
  @State private var expanded = false
  @State private var overflow = false
  @State private var images: [URL: UIImage] = [:]
  @State private var documentCache = ReplyDocumentCache()
  private struct Destination: Identifiable {
    let id = UUID()
    let value: RichNode.Target
  }
  @State private var destination: Destination?
  @Environment(\.dynamicTypeSize) private var type
  var body: some View {
    let document = reply.map {
      documentCache.document(reply: $0, wordSearch: wordSearch, duration: playback?.duration)
    } ?? origin
    let collapsed = maxLines > 0 && !expanded
    if document.links.isEmpty && document.images.isEmpty && document.styles.isEmpty {
      // Most comment rows contain only prose. Let SwiftUI measure one text run, without a
      // selectable UIKit view, asynchronous overflow feedback or a sheet host in every row.
      plain(document.text, collapsed: collapsed)
    } else {
    VStack(alignment: .leading, spacing: 2) {
      ReplyTextBody(
        document: document, images: images, size: type, textStyle: textStyle,
        limit: collapsed ? maxLines : 0, lineSpacing: lineSpacing, preview: preview && permitsPreview,
        onOverflow: { b in if b != overflow { overflow = b } }
      ) { u in
        if case .timestamp(let seconds) = document.target(u) { playback?.seek(Double(seconds)) }
        else if let t = document.target(u) { destination = Destination(value: t) }
      }
      // Re-create the text view on toggle so the list measures the new height immediately.
      .id(expanded)
      .overlay(alignment: .bottomTrailing) {
        if expandable && collapsed && overflow {
          Button {
            withAnimation(.snappy(duration: 0.25)) { expanded = true }
          } label: {
            HStack(spacing: 0) {
              Text("… ").foregroundStyle(.primary)
              Text("展开").foregroundStyle(.tint)
            }
            .font(Font(UIFont.preferredFont(forTextStyle: textStyle)))
            .padding(.leading, 18)
            .background(
              LinearGradient(
                stops: [.init(color: Color(uiColor: .systemBackground).opacity(0), location: 0),
                        .init(color: Color(uiColor: .systemBackground), location: 0.35)],
                startPoint: .leading, endPoint: .trailing))
          }.buttonStyle(.plain).accessibilityLabel("展开全文")
        }
      }
      if expandable && maxLines > 0 && expanded {
        Button("收起") { withAnimation(.snappy(duration: 0.25)) { expanded = false } }
          .buttonStyle(.plain).foregroundStyle(.tint)
          .font(Font(UIFont.preferredFont(forTextStyle: .footnote)))
      }
    }.task(id: document.assets) {
      let urls = document.assets
      images = images.filter { urls.contains($0.key) }
      for url in urls where images[url] == nil {
        guard !Task.isCancelled else { return }
        if let img = await ReplyEmoteImages.shared.image(url.absoluteString), !Task.isCancelled {
          images[url] = img
        }
      }
    }.piliSheet(item: $destination) { item in
      PiliNavigationStack {
        Group {
          switch item.value {
          case .timestamp: EmptyView()
          case .route(let r): LinkDestination(item: r)
          case .url(let u): SitePage(url: u).ignoresSafeArea()
          case .search(let term): SearchView(keyword: term)
          case .vote(let id): VoteView(id: id, dynamic: dynamicID)
          case .gallery(let pics): NativeGallery(pics)
          case .pictureResource(let id):MomentPictureResource(id:id)
          }
        }.toolbar {
          ToolbarItem(placement: .cancellationAction) { Button("关闭") { destination = nil } }
        }
      }
    }
    }
  }
  @ViewBuilder private func plain(_ text: String, collapsed: Bool) -> some View {
    let font = Font(UIFont.preferredFont(forTextStyle: textStyle))
    let run = Text(verbatim: text).font(font).lineSpacing(lineSpacing)
    let capped = run.lineLimit(maxLines).fixedSize(horizontal: false, vertical: true)
    VStack(alignment: .leading, spacing: 2) {
      if expandable && collapsed {
        // A hidden capped run supplies the actual proposed height, including Dynamic Type.
        capped.hidden().accessibilityHidden(true).overlay(alignment: .topLeading) {
          ViewThatFits(in: .vertical) {
            run.fixedSize(horizontal: false, vertical: true)
            capped.overlay(alignment: .bottomTrailing) {
              Button("展开") { expanded = true }.font(font).buttonStyle(.plain).foregroundStyle(.tint)
                .padding(.leading, 4).background(Color(uiColor: .systemBackground))
            }
          }.accessibilityHidden(false)
        }
      } else {
        run.lineLimit(collapsed ? maxLines : nil).fixedSize(horizontal: false, vertical: true)
        if expanded && expandable && maxLines > 0 {
          Button("收起") { expanded = false }.font(.footnote).buttonStyle(.plain).foregroundStyle(.tint)
        }
      }
    }.frame(maxWidth: .infinity, alignment: .leading)
  }
}
private struct ReplyTextBody: UIViewRepresentable {
  let document: InlineDocument, images: [URL: UIImage], size: DynamicTypeSize,
    textStyle: UIFont.TextStyle, limit: Int, lineSpacing: CGFloat,
    preview: Bool, onOverflow: (Bool) -> Void, open: (URL) -> Void
  final class Coordinator: NSObject, UITextViewDelegate {
    var open: (URL) -> Void
    init(_ f: @escaping (URL) -> Void) { open = f }
    var items = [ObjectIdentifier: EmotePreview.Item]()
    /// Last overflow state reported, so measuring passes don't re-post unchanged values.
    var overflow: Bool?
    var content: ContentKey?
    var measured: (width: CGFloat, result: CGSize)?
    func textView(
      _ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction
    ) -> UIAction? {
      switch textItem.content {
      case .link(let url): return UIAction { [weak self] _ in self?.open(url) }
      case .textAttachment(let a):
        guard let item = items[ObjectIdentifier(a)] else { return nil }
        let range = textItem.range
        return UIAction { [weak self, weak textView] _ in
          guard let self, let textView else { return }
          EmotePreview.present(item, from: textView, range: range, open: self.open)
        }
      default: return defaultAction
      }
    }
    func textView(
      _ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu
    ) -> UITextItem.MenuConfiguration? {
      if case .textAttachment(let a) = textItem.content {
        guard let item = items[ObjectIdentifier(a)] else { return nil }
        return EmotePreview.menu(item, open: open)
      }
      if case .link(let url) = textItem.content, url.scheme == "pili-inline" {
        return .init(
          menu: UIMenu(children: [
            UIAction(title: "打开", image: UIImage(systemName: "arrow.up.right")) { [weak self] _ in
              self?.open(url)
            }
          ]))
      }
      return .init(menu: defaultMenu)
    }
  }
  struct ContentKey: Equatable {
    let document: InlineDocument, images: [URL: ObjectIdentifier], size: DynamicTypeSize
    let textStyle: UIFont.TextStyle, limit: Int, spacing: CGFloat, preview: Bool
  }
  func makeCoordinator() -> Coordinator { Coordinator(open) }
  func makeUIView(context: Context) -> UITextView {
    // Default (TextKit 2) layout. `sizeThatFits` measures with this same view, so the height we
    // report always matches what it draws. Never touch `layoutManager`: that silently drops the
    // view back to TextKit 1.
    let v = UITextView()
    v.delegate = context.coordinator
    v.isEditable = false
    v.isSelectable = true
    v.isScrollEnabled = false
    v.backgroundColor = .clear
    v.textContainerInset = .zero
    v.textContainer.lineFragmentPadding = 0
    return v
  }
  func updateUIView(_ view: UITextView, context: Context) {
    context.coordinator.open = open
    let key = ContentKey(document: document, images: images.mapValues(ObjectIdentifier.init),
      size: size, textStyle: textStyle, limit: limit, spacing: lineSpacing, preview: preview)
    guard context.coordinator.content != key else { return }
    context.coordinator.content = key
    context.coordinator.measured = nil
    context.coordinator.items.removeAll(keepingCapacity: true)
    let font = UIFont.preferredFont(forTextStyle: textStyle, compatibleWith: view.traitCollection)
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineSpacing = lineSpacing
    let text = NSMutableAttributedString(
      string: document.text,
      attributes: [.font: font, .foregroundColor: UIColor.label, .paragraphStyle: paragraph])
    for style in document.styles {
      var traits = font.fontDescriptor.symbolicTraits
      if style.bold { traits.insert(.traitBold) }
      if style.italic { traits.insert(.traitItalic) }
      if traits != font.fontDescriptor.symbolicTraits,
        let desc = font.fontDescriptor.withSymbolicTraits(traits)
      {
        text.addAttribute(
          .font, value: UIFont(descriptor: desc, size: font.pointSize), range: style.range)
      }
      if style.strike {
        text.addAttribute(
          .strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: style.range)
      }
    }
    for link in document.links { text.addAttribute(.link, value: link.url, range: link.range) }
    var replaced: [(NSRange, NSTextAttachment)] = []
    for run in document.images {
      let e = run.image
      guard let img = images[e.url] else { continue }
      let attachment = NSTextAttachment()
      attachment.image = img
      attachment.accessibilityLabel = e.name
      if preview {
        context.coordinator.items[ObjectIdentifier(attachment)] = .init(
          image: img, name: e.name, jump: e.jump, jumpTitle: e.jumpTitle, asset: e.animation)
      }
      let edge = font.lineHeight * (e.size > 1 ? 1.65 : 1.05)
      attachment.bounds = CGRect(
        x: 0, y: font.descender, width: edge * img.size.width / max(1, img.size.height),
        height: edge)
      replaced.append((run.range, attachment))
    }
    var boundary = text.length
    for (range, item) in replaced.sorted(by: { $0.0.location > $1.0.location })
    where NSMaxRange(range) <= boundary {
      text.replaceCharacters(in: range, with: NSAttributedString(attachment: item))
      boundary = range.location
    }
    // Truncating line-break modes make a text view cut *every paragraph* to one line, so keep
    // word wrapping and let the line cap clip; the "… 展开" overlay marks the cut.
    view.textContainer.maximumNumberOfLines = limit
    view.textContainer.lineBreakMode = .byWordWrapping
    view.attributedText = text
    view.accessibilityLabel = document.text
  }
  /// Off-screen twin used only for measuring, so `sizeThatFits` never mutates the displayed view
  /// (changing its line cap there invalidates layout and SwiftUI measures again, in a loop that
  /// kept cancelling taps).
  @MainActor private static let measurer: UITextView = {
    let v = UITextView()
    v.isEditable = false
    v.isScrollEnabled = false
    v.textContainerInset = .zero
    v.textContainer.lineFragmentPadding = 0
    v.textContainer.lineBreakMode = .byWordWrapping
    return v
  }()
  func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
    guard let w = proposal.width, w.isFinite, w > 0 else { return nil }
    if let hit = context.coordinator.measured, hit.width == w { return hit.result }
    let target = CGSize(width: w, height: .greatestFiniteMagnitude)
    let m = Self.measurer
    m.attributedText = uiView.attributedText
    m.textContainer.maximumNumberOfLines = 0
    let full = m.sizeThatFits(target)
    guard limit > 0 else {
      let result = CGSize(width: w, height: ceil(full.height))
      context.coordinator.measured = (w, result)
      return result
    }
    m.textContainer.maximumNumberOfLines = limit
    let capped = m.sizeThatFits(target)
    let clipped = full.height > capped.height + 1
    if clipped != context.coordinator.overflow {
      context.coordinator.overflow = clipped
      DispatchQueue.main.async { onOverflow(clipped) }
    }
    let result = CGSize(width: w, height: ceil(capped.height))
    context.coordinator.measured = (w, result)
    return result
  }
}
