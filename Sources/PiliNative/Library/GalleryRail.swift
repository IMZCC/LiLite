import SwiftUI

struct GalleryRailRequest: Identifiable {
  let id = UUID()
  let photos: [GalleryPicture], index: Int
}
private struct GalleryRailKey: EnvironmentKey {
  static let defaultValue: ((GalleryRailRequest) -> Void)? = nil
}
extension EnvironmentValues {
  var presentGalleryRail: ((GalleryRailRequest) -> Void)? {
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
