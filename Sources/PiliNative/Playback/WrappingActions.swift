import SwiftUI

/// Keep every action reachable when a panel narrows or text grows, without a second scroll axis.
struct WrappingActions: Layout {
  var spacing: CGFloat = 12
  var rowSpacing: CGFloat = 8
  var trailing = false
  struct Plan {
    let width: CGFloat, height: CGFloat, spacing: CGFloat, rowSpacing: CGFloat
    let frames: [CGRect], rowEnds: [CGFloat]
  }
  struct Cache {
    let ideal: [CGSize], totalIdealWidth: CGFloat
    var plan: Plan?
  }
  func makeCache(subviews: Subviews) -> Cache {
    let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
    return Cache(ideal: ideal, totalIdealWidth: ideal.reduce(0) { $0 + max(0, $1.width.isFinite ? $1.width : 0) })
  }
  private func frames(width proposed: CGFloat?, subviews: Subviews, cache: inout Cache) -> Plan {
    let ideal = cache.ideal
    let natural = cache.totalIdealWidth + spacing * CGFloat(max(0, ideal.count - 1))
    let width = max(1, proposed.flatMap { $0.isFinite ? $0 : nil } ?? natural)
    if let plan = cache.plan, plan.width == width, plan.spacing == spacing, plan.rowSpacing == rowSpacing { return plan }
    var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, result: [CGRect] = []
    for (index, view) in subviews.enumerated() {
      let available = min(width, max(1, ideal[index].width.isFinite ? ideal[index].width : width))
      let measured = view.sizeThatFits(.init(width: available, height: nil))
      let size = CGSize(width: min(width, max(0, measured.width)), height: max(0, measured.height))
      if x > 0, x + size.width > width { x = 0; y += row + rowSpacing; row = 0 }
      result.append(.init(origin: .init(x: x, y: y), size: size))
      x += size.width + spacing; row = max(row, size.height)
    }
    var ends = Array(repeating: CGFloat.zero, count: result.count)
    for index in result.indices.reversed() {
      let next = index + 1
      ends[index] = next < result.count && result[next].minY == result[index].minY ? ends[next] : result[index].maxX
    }
    let plan = Plan(width: width, height: y + row, spacing: spacing, rowSpacing: rowSpacing, frames: result, rowEnds: ends)
    cache.plan = plan
    return plan
  }
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    let result = frames(width: proposal.width, subviews: subviews, cache: &cache)
    return .init(width: result.width, height: result.height)
  }
  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
    let result = frames(width: bounds.width, subviews: subviews, cache: &cache)
    for (index, view) in subviews.enumerated() {
      let frame = result.frames[index]
      let offset = trailing ? max(0, bounds.width - result.rowEnds[index]) : 0
      view.place(at: .init(x: bounds.minX + frame.minX + offset, y: bounds.minY + frame.minY), anchor: .topLeading, proposal: .init(frame.size))
    }
  }
}
