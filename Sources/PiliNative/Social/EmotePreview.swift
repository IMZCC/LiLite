import SwiftUI

struct EmoteMenuPreview: View {
  let url: URL?, name: String
  var body: some View {
    VStack(spacing: 8) {
      if let url {
        RemoteArtwork(url: url) {
          $0.resizable().scaledToFit()
        } placeholder: {
          Color.clear
        }
        .frame(width: 80, height: 80)
      }
      Text(name).font(.subheadline).lineLimit(3)
    }.padding().frame(minWidth: 110, maxWidth: 200).accessibilityElement(children: .combine)
  }
}

@MainActor enum EmotePreview {
  struct Item {
    let image: UIImage, name: String, jump: String?, jumpTitle: String?
    var asset: URL? = nil
    var target: URL? {
      guard let raw = jump, !raw.isEmpty, let u = httpsURL(raw) ?? URL(string: raw),
        SharedLink.parse(u.absoluteString) != nil
          || ["https", "http"].contains(u.scheme?.lowercased() ?? "")
      else { return nil }
      return u
    }
  }
  static func present(
    _ item: Item, from text: UITextView, range: NSRange, open: @escaping (URL) -> Void
  ) {
    var next: UIResponder? = text
    while next != nil && !(next is UIViewController) { next = next?.next }
    guard let presenter = next as? UIViewController, presenter.presentedViewController == nil,
      text.window != nil
    else { return }
    let controller = EmotePopover(item: item, open: open)
    controller.modalPresentationStyle = .popover
    controller.preferredContentSize = .init(width: 174, height: item.target == nil ? 136 : 170)
    guard let pop = controller.popoverPresentationController else { return }
    pop.sourceView = text
    pop.delegate = controller
    var rect = CGRect(x: text.bounds.midX, y: text.bounds.midY, width: 1, height: 1)
    if let start = text.position(from: text.beginningOfDocument, offset: range.location),
      let end = text.position(from: start, offset: range.length),
      let span = text.textRange(from: start, to: end)
    {
      let frame = text.firstRect(for: span)
      if !frame.isNull && !frame.isInfinite && text.bounds.intersects(frame) { rect = frame }
    }
    pop.sourceRect = rect
    presenter.present(controller, animated: true)
  }
  static func menu(_ item: Item, open: @escaping (URL) -> Void) -> UITextItem.MenuConfiguration {
    let image = UIImageView(image: item.image)
    image.contentMode = .scaleAspectFit
    let title = UILabel()
    title.text = item.name
    title.font = .preferredFont(forTextStyle: .caption1)
    title.textAlignment = .center
    title.numberOfLines = 2
    let stack = UIStackView(arrangedSubviews: [image, title])
    stack.axis = .vertical
    stack.spacing = 6
    stack.isLayoutMarginsRelativeArrangement = true
    stack.layoutMargins = .init(top: 8, left: 8, bottom: 8, right: 8)
    stack.frame = CGRect(x: 0, y: 0, width: 144, height: 120)
    image.heightAnchor.constraint(equalToConstant: 76).isActive = true
    var actions = [UIAction]()
    if let u = item.target {
      actions.append(
        UIAction(
          title: item.jumpTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "查看表情详情",
          image: UIImage(systemName: "arrow.up.right")
        ) { _ in open(u) })
    }
    actions.append(
      UIAction(title: "复制表情名称", image: UIImage(systemName: "doc.on.doc")) { _ in
        UIPasteboard.general.string = item.name
      })
    return .init(preview: .view(stack), menu: UIMenu(title: item.name, children: actions))
  }
}
