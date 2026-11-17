import SwiftUI

struct IMContentView: View {
  let message: DirectMessage
  var body: some View {
    let card = message.card
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(card.rows.enumerated()), id: \.offset) { _, row in
        if let target = row.target {
          NavigationLink {
            switch target {
            case .route(let r): LinkDestination(item: r)
            case .url(let u): SitePage(url: u)
            case .gallery(let p): NativeGallery(p)
            case .pictureResource(let id):MomentPictureResource(id:id)
            case .timestamp: EmptyView()
            case .search(let q): SearchView(keyword: q)
            case .vote(let id): VoteView(id: id, dynamic: "0")
            }
          } label: {
            content(row)
          }
        } else {
          content(row).textSelection(.enabled)
        }
      }
    }
  }
  @ViewBuilder private func content(_ row: IMCardBody.Row) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      if let u = row.image {
        SiteThumbnail(url: u) {
          $0.resizable().scaledToFit()
        } placeholder: {
          Color.clear
        }.frame(maxHeight: 180)
      }
      if !row.title.isEmpty { Text(row.title) }
      if !row.detail.isEmpty { Text(row.detail).font(.subheadline).foregroundStyle(.secondary) }
    }
  }
}
