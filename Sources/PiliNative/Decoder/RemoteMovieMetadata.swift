/// Sparse metadata snapshots have no network methods and cannot accidentally fetch payload bytes
/// while walking sample tables. All subsequent payload reads are cancellable HTTP operations.
import Foundation

struct RemoteMovieMetadata: LocalTrackBytes {
  private struct Block { let start: Int64, data: Data }
  private struct LengthOnly: LocalTrackBytes {
    let length: Int64
    func data(_ start: Int64, _ count: Int) throws -> Data { throw LocalIndexIssue.invalid }
  }
  var playbackBacking: any LocalTrackBytes { LengthOnly(length: length) }
  let length: Int64
  private var blocks: [Block]
  func data(_ start: Int64, _ count: Int) throws -> Data {
    guard count > 0, start >= 0, start <= length - Int64(count),
      let b = blocks.first(where: {
        $0.start <= start && start + Int64(count) <= $0.start + Int64($0.data.count)
      })
    else { throw LocalIndexIssue.invalid }
    let i = Int(start - b.start)
    return b.data.subdata(in: i..<i + count)
  }
  typealias Fetch = @Sendable (Int64, Int) async throws -> (data: Data, total: Int64)
  static func open(fetch: Fetch) async throws -> Self {
    let first = try await fetch(0, 16)
    guard first.total >= 16, first.total <= 512 * 1024 * 1024 * 1024, first.data.count == 16 else {
      throw LocalIndexIssue.invalid
    }
    var meta = Self(length: first.total, blocks: [Block(start: 0, data: first.data)])
    func read(_ a: Int64, _ n: Int) async throws -> Data {
      if let d = try? meta.data(a, n) { return d }
      guard a >= 0, n > 0, a <= meta.length - Int64(n) else { throw LocalIndexIssue.invalid }
      let page = try await fetch(a, n)
      guard page.total == meta.length, page.data.count == n else { throw LocalIndexIssue.invalid }
      meta.blocks.append(Block(start: a, data: page.data))
      return page.data
    }
    var at: Int64 = 0
    var seen = false
    var boxes = 0
    while at < meta.length {
      try Task.checkCancellation()
      boxes += 1
      guard boxes <= 256 else { throw LocalIndexIssue.invalid }
      let h = try await read(at, Int(min(16, meta.length - at)))
      let code = String(decoding: h.dropFirst(4).prefix(4), as: UTF8.self)
      var size = try LocalAtom.uint(h, 0, 4)
      var header: UInt64 = 8
      if size == 1 {
        size = try LocalAtom.uint(h, 8, 8)
        header = 16
      }
      if size == 0 { size = UInt64(meta.length - at) }
      guard size >= header, size <= UInt64(meta.length - at) else { throw LocalIndexIssue.invalid }
      if code == "moof" { throw LocalIndexIssue.notFragmented }
      if code == "moov" {
        guard !seen, size <= 24 * 1024 * 1024 else { throw LocalIndexIssue.invalid }
        // Fetch only the movie atom, never the intervening media (including tail-moov files).
        var data = Data()
        data.reserveCapacity(Int(size))
        while data.count < Int(size) {
          try Task.checkCancellation()
          let n = min(512 * 1024, Int(size) - data.count)
          let part = try await fetch(at + Int64(data.count), n)
          guard part.total == meta.length, part.data.count == n else {
            throw LocalIndexIssue.invalid
          }
          data.append(part.data)
        }
        meta.blocks.append(Block(start: at, data: data))
        seen = true
      }
      at += Int64(size)
    }
    guard seen else { throw LocalIndexIssue.notFragmented }
    return meta
  }
}
