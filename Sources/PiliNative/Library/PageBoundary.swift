import Foundation

struct PageBoundary {
  private var consumed = Set<String>()
  private(set) var failedRefresh = true
  mutating func failed(refresh: Bool) { failedRefresh = refresh }
  mutating func next(_ value: String?, after cursor: String?, reset: Bool) -> String? {
    if reset { consumed.removeAll() }
    if let cursor { consumed.insert(cursor) }
    return value.flatMap { $0.isEmpty || consumed.contains($0) ? nil : $0 }
  }
  static func nearFooter(y: CGFloat, height: CGFloat) -> Bool {
    height.isFinite && height > 0 && y.isFinite && y >= -1 && y <= height + 36
  }
}
