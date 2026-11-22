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
    NativeGallery(request.photos, index: request.index, close: dismiss)
      // Down over the home indicator too: the page under it must not show through below.
      .background(.background).clipped().ignoresSafeArea(.container, edges: .bottom).id(request.id)
  }
}
