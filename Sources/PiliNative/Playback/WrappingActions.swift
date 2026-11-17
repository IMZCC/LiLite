import SwiftUI

/// Keep every action reachable when a panel narrows or text grows, without a second scroll axis.
struct WrappingActions: Layout {
  var spacing: CGFloat = 12
  var rowSpacing: CGFloat = 8
  var trailing = false
  private func frames(width proposed: CGFloat?, subviews: Subviews) -> (width: CGFloat, height: CGFloat, frames: [CGRect]) {
    let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
    let natural = ideal.reduce(0) { $0 + max(0, $1.width.isFinite ? $1.width : 0) } + spacing * CGFloat(max(0, ideal.count - 1))
    let width = max(1, proposed.flatMap { $0.isFinite ? $0 : nil } ?? natural)
    var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, result: [CGRect] = []
    for (index, view) in subviews.enumerated() {
      let available = min(width, max(1, ideal[index].width.isFinite ? ideal[index].width : width))
      let measured = view.sizeThatFits(.init(width: available, height: nil))
      let size = CGSize(width: min(width, max(0, measured.width)), height: max(0, measured.height))
      if x > 0, x + size.width > width { x = 0; y += row + rowSpacing; row = 0 }
      result.append(.init(origin: .init(x: x, y: y), size: size))
      x += size.width + spacing; row = max(row, size.height)
    }
    return (width, y + row, result)
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let result = frames(width: proposal.width, subviews: subviews)
    return .init(width: result.width, height: result.height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let result = frames(width: bounds.width, subviews: subviews)
    for (view, frame) in zip(subviews, result.frames) {
      let rowEnd = result.frames.last(where: { $0.minY == frame.minY })?.maxX ?? frame.maxX
      let offset = trailing ? max(0, bounds.width - rowEnd) : 0
      view.place(at: .init(x: bounds.minX + frame.minX + offset, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: .init(frame.size))
    }
  }
}
