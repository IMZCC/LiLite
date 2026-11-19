import SwiftUI

struct SiteThumbnail<Content: View>: View {
  let url: URL?, content: (AsyncImagePhase) -> Content
  @Environment(\.imageDisplay) private var display
  @State private var failed: URL?
  init(url: URL?, @ViewBuilder content: @escaping (AsyncImagePhase) -> Content) {
    self.url = url
    self.content = content
  }
  init<A: View, B: View>(
    url: URL?, @ViewBuilder content: @escaping (Image) -> A,
    @ViewBuilder placeholder: @escaping () -> B
  ) where Content == _ConditionalContent<A, B> {
    self.url = url
    @ViewBuilder func render(_ phase: AsyncImagePhase) -> Content {
      if let image = phase.image { content(image) } else { placeholder() }
    }
    self.content = render
  }
  var body: some View {
    let quality = (display ?? .stored).quality
    let small = url.map { GalleryPicture($0).display(quality: quality) }
    let fetch = failed == small ? url : small
    RemoteArtwork(url: fetch) { phase in
      content(phase).modifier(NightImage(loaded: phase.image != nil)).onChange(
        of: phase.error != nil, initial: true
      ) { _, bad in
        if bad, let fetch, fetch != url { failed = fetch }
      }
    }
  }
}
