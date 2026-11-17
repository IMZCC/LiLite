import Foundation

/// Grow by actual incoming live bytes, not by the configured maximum. Consumed pages are released;
/// lowering the limit never discards unread packets in the middle of the demuxer's input.
struct MediaBufferFIFO {
  private let pageSize = 32 * 1024
  private var pages: [Data?] = [], first = 0, offset = 0
  private(set) var count = 0
  mutating func append(_ ptr: UnsafeRawPointer, length: Int, limit: Int) -> Int {
    let n = min(max(0, length), max(0, limit - count))
    var pos = 0
    while pos < n {
      if pages.isEmpty || (pages[pages.count - 1]?.count ?? pageSize) == pageSize {
        pages.append(Data())
      }
      let last = pages.count - 1
      let chunk = min(n - pos, pageSize - (pages[last]?.count ?? 0))
      pages[last]?.append(ptr.advanced(by: pos).assumingMemoryBound(to: UInt8.self), count: chunk)
      pos += chunk
    }
    count += n
    return n
  }
  mutating func take(_ dst: UnsafeMutablePointer<UInt8>, length: Int) -> Int {
    let n = min(max(0, length), count)
    var pos = 0
    while pos < n {
      guard let d = pages[first] else { break }
      let step = min(n - pos, d.count - offset)
      let start = d.startIndex + offset
      d.copyBytes(
        to: UnsafeMutableBufferPointer(start: dst.advanced(by: pos), count: step),
        from: start..<start + step)
      pos += step
      offset += step
      if offset == d.count {
        pages[first] = nil
        first += 1
        offset = 0
      }
    }
    count -= pos
    if count == 0 {
      clear()
    } else if first >= 64 && first > pages.count / 2 {
      pages.removeFirst(first)
      first = 0
    }
    return pos
  }
  mutating func clear() {
    pages.removeAll(keepingCapacity: false)
    first = 0
    offset = 0
    count = 0
  }
}
