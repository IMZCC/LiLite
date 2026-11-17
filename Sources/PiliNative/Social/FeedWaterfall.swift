import SwiftUI

/// Only mount cards around the viewport: a long timeline can contain expensive text and galleries.
/// Measured heights are keyed by item and width; rows keep their identity when their lane changes.
struct FeedWaterfall<Item: Identifiable, Row: View>: View {
  let items: [Item], available: CGFloat, viewport: CGFloat, columns: Int
  @ViewBuilder let row: (Item) -> Row
  @State private var measured: [Item.ID: CGSize] = [:]
  var body: some View {
    let laneWidth = max(1, (available - CGFloat(columns - 1) * 4) / CGFloat(columns))
    let heights = items.map { item -> CGFloat in
      if let size = measured[item.id], abs(size.width - laneWidth) < 0.5 {
        return size.height
      }
      return 240
    }
    let plan = FeedColumnPlan(width: available, columns: columns, heights: heights)
    FeedWaterfallWindow(items: items, available: available, viewport: viewport, plan: plan, row: row) { id, size in
      guard size.width > 0, size.height.isFinite else { return }
      let new = CGSize(width: size.width, height: ceil(size.height))
      if measured[id] != new { measured[id] = new }
    }
    .onChange(of: items.count) { old, new in
      if new < old {
        let keep = Set(items.map(\.id))
        measured = measured.filter { keep.contains($0.key) }
      }
    }
  }
}

/// Observe scroll position below the layout planner, so a scroll never rebuilds every frame.
private struct FeedWaterfallWindow<Item: Identifiable, Row: View>: View {
  let items: [Item]
  let available: CGFloat
  let viewport: CGFloat
  let plan: FeedColumnPlan
  @ViewBuilder let row: (Item) -> Row
  let measure: (Item.ID, CGSize) -> Void
  @Environment(\.layoutDirection) private var direction
  @State private var region = 0
  private let step: CGFloat = 128
  var body: some View {
    let margin = max(350, viewport)
    let lo = CGFloat(region) * step - margin
    let hi = CGFloat(region + 1) * step + viewport + margin
    let visible = plan.visibleIndices(from: lo, through: hi)
    Color.clear.frame(width: max(1, available), height: max(1, plan.height))
      .overlay(alignment: .topLeading) {
        ZStack(alignment: .topLeading) {
          ForEach(visible.map { FeedVisibleItem(index: $0, item: items[$0]) }) { cell in
            let rect = plan.frames[cell.index]
            row(cell.item)
              .padding(.horizontal, 6)
              .frame(width: plan.width, alignment: .leading)
              .fixedSize(horizontal: false, vertical: true)
              .onGeometryChange(for: CGSize.self) {
                $0.size
              } action: { size in
                measure(cell.id, size)
              }
              .id(cell.id)
              .accessibilitySortPriority(-Double(cell.index))
              .offset(x: direction == .rightToLeft ? -rect.minX : rect.minX, y: rect.minY)
          }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      }
      .onGeometryChange(for: Int.self) { proxy in
        let y = -proxy.frame(in: .scrollView(axis: .vertical)).minY
        return y.isFinite ? Int(floor(max(0, y) / step)) : 0
      } action: {
        region = $0
      }
  }
}

private struct FeedVisibleItem<Item: Identifiable>: Identifiable {
  let index: Int, item: Item
  var id: Item.ID { item.id }
}
