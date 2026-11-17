import Foundation

/// Each selected glyph has its own presentation time; the rest of the video keeps advancing.
struct BulletPauseClock<Key: Equatable> {
  struct Entry {
    let key: Key, from: Double, until: Double
    var sample: Double, resume: Double?
    func position(at t: Double) -> Double { sample + (resume.map { max(0, t - $0) } ?? 0) }
  }
  private(set) var entries: [Entry] = []
  mutating func hold(_ key: Key, start: Double, duration: Double, sample: Double, at now: Double) {
    guard [start, duration, sample, now].allSatisfy(\.isFinite), duration > 0, sample >= start,
      sample < start + duration
    else { return }
    release(at: now)
    entries.removeAll { $0.key == key }
    if entries.count >= 32 { entries.removeFirst() }
    entries.append(
      .init(key: key, from: start, until: start + duration, sample: sample, resume: nil))
  }
  mutating func release(at now: Double) {
    guard now.isFinite else {
      entries = []
      return
    }
    entries.removeAll { $0.resume != nil && $0.position(at: now) >= $0.until }
    if let i = entries.firstIndex(where: { $0.resume == nil }) { entries[i].resume = now }
  }
  func visible(at t: Double) -> [(Key, Double)] {
    guard t.isFinite else { return [] }
    return entries.compactMap { item in
      let p = item.position(at: t)
      guard p >= item.from, p < item.until else { return nil }
      return (item.key, p)
    }
  }
}
