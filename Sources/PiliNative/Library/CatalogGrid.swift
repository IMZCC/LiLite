import SwiftUI

struct CatalogGrid<Content: View>: View {
  var home = false
  /// Desired item width overriding the user's card width (posters use ~110 pt).
  var itemWidth: Double? = nil
  @ViewBuilder let content: () -> Content
  @AppStorage("grid.recommendWidth") private var homeWidth = 240.0
  @AppStorage("grid.cardWidth") private var defaultWidth = 240.0
  @Environment(\.dynamicTypeSize) private var textSize
  @State private var columns = 1
  var body: some View {
    let gap = 12.0
    let limit = itemWidth ?? min(500, max(150, home ? homeWidth : defaultWidth))
    let large = textSize.isAccessibilitySize
    LazyVGrid(
      columns: Array(
        repeating: GridItem(.flexible(minimum: 0), spacing: gap, alignment: .topLeading),
        count: columns), alignment: .leading, spacing: 22
    ) { content() }
    .frame(maxWidth: .infinity)
    .onGeometryChange(for: Int.self) { proxy in
      let width = Double(proxy.size.width)
      return InterfacePresentation.columns(width:width,gap:gap,desired:limit,accessible:large)
    } action: {
      columns = $0
    }
  }
}
