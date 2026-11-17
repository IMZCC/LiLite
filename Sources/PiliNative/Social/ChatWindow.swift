import Foundation

/// The IM service returns newest first; the conversation is read oldest first.
struct ChatWindow<Row: Identifiable> {
  private(set) var rows: [Row] = [], next: String?
  mutating func receive(_ descending: [Row], next newCursor: String?, older: Bool) {
    var seen = Set<Row.ID>()
    let fresh = Array(descending.filter { seen.insert($0.id).inserted }.reversed())
    if older {
      var current = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
      let prepend = fresh.filter { current[$0.id] == nil }
      for row in fresh where current[row.id] != nil { current[row.id] = row }
      rows = prepend + rows.compactMap { current[$0.id] }
      next = newCursor
      return
    }
    let firstOverlap = rows.firstIndex { seen.contains($0.id) }
    // If all visible messages are new, re-page from the new response to avoid a gap.
    if let i = firstOverlap, i > 0 {
      rows = Array(rows[..<i]) + fresh
    } else {
      rows = fresh
      next = newCursor
    }
  }
}
