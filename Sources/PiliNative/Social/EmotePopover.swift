import SwiftUI

private struct AnimatedEmote: View {
  let url: URL?, fallback: UIImage
  @State private var file: URL?
  @State private var owner: GalleryAssets?
  var body: some View {
    Group {
      if let file {
        GalleryZoom(file: file).allowsHitTesting(false)
      } else {
        Image(uiImage: fallback).resizable().scaledToFit()
      }
    }.frame(width: 82, height: 82).task(id: url) {
      file = nil
      owner = nil
      guard let url else { return }
      let files = GalleryAssets()
      do {
        let local = try await files.local(url)
        try Task.checkCancellation()
        owner = files
        file = local
      } catch {}
    }
  }
}
struct EmotePopupContent: View {
  let item: EmotePreview.Item
  var follow: (URL) -> Void = { _ in }
  var body: some View {
    VStack(spacing: 6) {
      AnimatedEmote(url: item.asset, fallback: item.image)
      Text(item.name).font(.caption).multilineTextAlignment(.center).lineLimit(2)
      if let u = item.target {
        Button(item.jumpTitle.flatMap { $0.isEmpty ? nil : $0 } ?? "查看表情详情") { follow(u) }.font(
          .caption)
      }
    }.padding(8)
  }
}
final class EmotePopover: UIHostingController<EmotePopupContent>,
  UIPopoverPresentationControllerDelegate
{
  init(item: EmotePreview.Item, open: @escaping (URL) -> Void) {
    super.init(rootView: EmotePopupContent(item: item))
    rootView.follow = { [weak self] u in self?.dismiss(animated: true) { open(u) } }
  }
  @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
  func adaptivePresentationStyle(for controller: UIPresentationController)
    -> UIModalPresentationStyle
  { .none }
  func adaptivePresentationStyle(
    for controller: UIPresentationController, traitCollection: UITraitCollection
  ) -> UIModalPresentationStyle { .none }
}
