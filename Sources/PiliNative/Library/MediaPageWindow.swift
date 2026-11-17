import Foundation

/// Server page numbers stay in their original order. Reversing playback never renumbers a bookmark.
struct MediaPageWindow<Item> {
  struct Slot { let number: Int, item: Item }
  private var pages: [Int: [Item]] = [:]
  private var firstPage: [String: Int] = [:]
  private(set) var end: Int?
  private(set) var beginning=1
  mutating func firstPage(_ n:Int){beginning=max(beginning,n)}
  var reversed = false
  let identify: (Item) -> String
  let playable: (Item) -> Bool
  init(identify: @escaping (Item) -> String, playable: @escaping (Item) -> Bool) {
    self.identify = identify
    self.playable = playable
  }
  var numbers: [Int] { pages.keys.sorted() }
  func has(_ page: Int) -> Bool { pages[page] != nil }
  mutating func put(_ page: Int, _ rows: [Item], hasNext: Bool) {
    guard page > 0 else { return }
    guard pages[page] == nil else { return }
    pages[page] = rows
    for row in rows {
      let id = identify(row)
      firstPage[id] = min(firstPage[id] ?? page, page)
    }
    if !hasNext { end = min(end ?? page, page) }
  }
  func slots(_ number: Int) -> [Slot] {
    var seen = Set<String>()
    let rows = (pages[number] ?? []).filter {
      let id = identify($0)
      return firstPage[id] == number && seen.insert(id).inserted
    }
    return (reversed ? Array(rows.reversed()) : rows).map { Slot(number: number, item: $0) }
  }
  enum Step {
    case found(Slot)
    case fetch(Int)
    case finished
  }
  func step(from current: Slot?, forward: Bool, starting: Int = 1) -> Step {
    let delta = (forward != reversed) ? 1 : -1
    var n = current.flatMap { firstPage[identify($0.item)] } ?? current?.number ?? starting
    var first = true
    let old = current.map { identify($0.item) }
    while n >= beginning && (end == nil || n <= end!) {
      guard has(n) else { return .fetch(n) }
      var candidates = slots(n)
      if !forward { candidates.reverse() }
      if first, let old, let i = candidates.firstIndex(where: { identify($0.item) == old }) {
        candidates = Array(candidates.dropFirst(i + 1))
      }
      if let row = candidates.first(where: { playable($0.item) && identify($0.item) != old }) {
        return .found(row)
      }
      first = false
      n += delta
    }
    return .finished
  }
}
