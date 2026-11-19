import SwiftUI

struct GalleryRailRequest: Identifiable {
  let id = UUID()
  let photos: [GalleryPicture], index: Int
}
private struct GalleryRailKey: EnvironmentKey {
  static let defaultValue: StableAction<GalleryRailRequest>? = nil
}
extension EnvironmentValues {
  var presentGalleryRail: StableAction<GalleryRailRequest>? {
    get { self[GalleryRailKey.self] }
    set { self[GalleryRailKey.self] = newValue }
  }
}
struct GalleryRailPanel: View {
  let request: GalleryRailRequest, dismiss: () -> Void
  var body: some View {
    PiliNavigationStack {
      NativeGallery(request.photos, index: request.index)
        .toolbar { ToolbarItem(placement: .topBarLeading) { Button("关闭", action: dismiss) } }
    }.background(.background).id(request.id)
  }
}
