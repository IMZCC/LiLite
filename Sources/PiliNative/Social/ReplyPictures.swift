import SwiftUI

/// Comment pictures laid out like the original's image grid: one picture keeps its shape at a
/// capped size; two or four sit two-up; anything else three-up, in square rounded cells.
struct ReplyPictures: View {
  let items: [Reply.Content.Picture]
  var body: some View {
    let pairs = items.compactMap { p -> (GalleryPicture, CGFloat?)? in
      guard let raw = p.img_src, let url = GalleryPicture.source(raw) else { return nil }
      let ratio = (p.img_width ?? 0) > 0 && (p.img_height ?? 0) > 0
        ? CGFloat(p.img_width! / p.img_height!) : nil
      return (GalleryPicture(url, motion: p.live_url.flatMap(GalleryPicture.source)), ratio)
    }
    let photos = pairs.map(\.0)
    if photos.count == 1 {
      // Tall pictures are cropped to 3:4 like the original; wide ones keep their shape.
      let ratio = min(max(pairs[0].1 ?? 1, 0.75), 2)
      GalleryLink(photos, index: 0) {
        cell(photos[0]).aspectRatio(ratio, contentMode: .fit)
      }
      .frame(maxWidth: ratio >= 1 ? 240 : 180, alignment: .leading)
    } else if !photos.isEmpty {
      let columns = photos.count == 2 || photos.count == 4 ? 2 : 3
      LazyVGrid(
        columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: columns), spacing: 4
      ) {
        ForEach(photos.indices, id: \.self) { i in
          GalleryLink(photos, index: i) { cell(photos[i]).aspectRatio(1, contentMode: .fit) }
        }
      }
      .frame(maxWidth: columns == 2 ? 240 : 320, alignment: .leading)
    }
  }
  private func cell(_ photo: GalleryPicture) -> some View {
    Color(uiColor: .secondarySystemFill)
      .overlay { GalleryThumb(photo: photo, fill: true) }
      .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
  }
}
struct NativeImageViewer: View {
  let url: URL
  var body: some View { NativeGallery([GalleryPicture(url)]) }
}
