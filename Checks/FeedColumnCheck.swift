import Foundation

@main enum FeedColumnCheck {
  static func main() {
    checkScrollPaging()
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

  static func checkScrollPaging() {
    var paging = FeedScrollPaging()
    let contentHeight: CGFloat = 8_000
    func near(_ y: CGFloat, _ height: CGFloat, content: CGFloat = 8_000) -> Bool {
      FeedScrollPaging.nearEnd(visible: CGRect(x: 0, y: y, width: 405, height: height), contentHeight: content)
    }
    precondition(!near(-40, 700) && !near(0, 700) && !near(12, 700, content: 400))
    precondition(!near(7_139, 700) && near(7_140, 700))
    precondition(!near(7_560, 350) && near(7_570, 350))
    for _ in 0..<100 {
      precondition(!paging.takePage(nearEnd: true))
      paging.beginDrag()
      var loads = 0
      for y in stride(from: CGFloat.zero, through: contentHeight, by: 8) {
        if paging.takePage(nearEnd: near(y, 700)) { loads += 1 }
      }
      precondition(loads == 1)
      // Alternating footer visibility after append must not start a request chain.
      for i in 0..<30 { precondition(!paging.takePage(nearEnd: i.isMultiple(of: 2))) }
      paging.endDrag()
      paging.beginDrag()
      precondition(!paging.takePage(nearEnd: false))
      paging.endDrag() // Leaving the channel, cancelling a drag or refreshing at the top.
      precondition(!paging.takePage(nearEnd: true))
    }
    print("Feed paging: 100 flings, footer re-layouts, short content and interrupted drags passed")
  }
}
