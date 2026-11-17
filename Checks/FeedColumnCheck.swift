import Foundation

@main enum FeedColumnCheck {
  static func main() {
    let compact = FeedColumnPlan.columns(width: 390, cardWidth: 240, largeText: false)
    let wide = FeedColumnPlan.columns(width: 1000, cardWidth: 240, largeText: false)
    precondition(compact == 1 && wide == 3)
    precondition(FeedColumnPlan.columns(width: 1000, cardWidth: 240, largeText: true) == 1)
    let heights: [CGFloat] = [100, 30, 45, 0, 15, 132, 29, 25, 50, 12, 8]
    let first = FeedColumnPlan(width: 604, columns: 2, heights: Array(heights.prefix(4)))
    let all = FeedColumnPlan(width: 604, columns: 2, heights: heights)
    precondition(all.width == 300 && first.frames == Array(all.frames.prefix(4)))
    // Item 2 belongs under shorter item 1, not in a uniform second row under item 0.
    precondition(all.frames[2].minX == 304 && all.frames[2].minY == 34)
    precondition(all.frames[3].height == 0 && all.frames[3].origin == all.frames[4].origin)
    let boxes = all.frames.filter { $0.height > 0 }
    for (i, box) in boxes.enumerated() {
      precondition(box.minX >= 0 && box.maxX <= 604)
      for later in boxes.dropFirst(i + 1) { precondition(!later.intersects(box)) }
    }
    precondition(boxes.map(\.maxY).max() == all.height)
    let single = FeedColumnPlan(width: 370, columns: 1, heights: heights)
    precondition(single.width == 370 && single.height == heights.reduce(0, +) + CGFloat(boxes.count - 1) * 4)
    print("Feed columns: adaptive widths, source order, shortest lane, append, folded rows, rotation and accessibility passed")
  }
}
