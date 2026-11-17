import Foundation

/// Plain text remains in its original order; timestamped lines can also be used to seek.
struct LyricLines {
  struct Line: Identifiable, Equatable {
    let id: Int, seconds: Double?, text: String
  }
  let lines: [Line]
  init(_ text: String) {
    let normalized = text.replacingOccurrences(of: "\u{feff}", with: "")
    var result = [(Double?, String)]()
    var offset = 0.0
    for raw in normalized.components(separatedBy: .newlines) {
      var rest = raw[...]
      var stamps = [Double]()
      var header = false
      while rest.first == "[", let end = rest.firstIndex(of: "]") {
        let value = rest.dropFirst().prefix(upTo: end)
        if let t = Self.time(value) {
          stamps.append(t)
        } else if value.hasPrefix("offset:"), let ms = Double(value.dropFirst(7)), ms.isFinite {
          offset = ms / 1000
          header = true
        } else if ["ar:", "al:", "ti:", "au:", "by:", "re:", "ve:", "length:"].contains(where: {
          value.hasPrefix($0)
        }) {
          header = true
        } else {
          break
        }
        rest = rest[rest.index(after: end)...]
      }
      let words = rest.trimmingCharacters(in: .whitespaces)
      if !stamps.isEmpty {
        result += stamps.map { ($0, words) }
      } else if !words.isEmpty || (!header && !result.isEmpty && result.last?.1 != "") {
        result.append((nil, words))
      }
    }
    let timed = result.enumerated().compactMap { i, row -> (Int, Double, String)? in
      guard let sec = row.0 else { return nil }
      return (i, max(0, sec - offset), row.1)
    }.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }
    if !timed.isEmpty {
      lines = timed.enumerated().map { i, row in .init(id: i, seconds: row.1, text: row.2) }
    } else {
      while result.last?.1 == "" { result.removeLast() }
      lines = result.enumerated().map { .init(id: $0.offset, seconds: nil, text: $0.element.1) }
    }
  }
  func active(at sec: Double) -> Int? {
    guard sec.isFinite, lines.first?.seconds != nil else { return nil }
    var lo = 0
    var hi = lines.count
    while lo < hi {
      let mid = lo + (hi - lo) / 2
      if let t = lines[mid].seconds, t <= sec { lo = mid + 1 } else { hi = mid }
    }
    return lo > 0 ? lines[lo - 1].id : nil
  }
  private static func time(_ text: Substring) -> Double? {
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard (2...3).contains(parts.count),
      parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") } }
      ),
      let s = Double(parts.last!), s.isFinite, (0..<60).contains(s),
      let m = Int(parts[parts.count - 2]), m >= 0, m < 10000
    else { return nil }
    if parts.count == 3 {
      guard let h = Int(parts[0]), h >= 0, h < 100, m < 60 else { return nil }
      return Double(h * 3600 + m * 60) + s
    }
    return Double(m * 60) + s
  }
}
