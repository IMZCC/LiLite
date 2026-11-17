import Foundation

/// Receipts contain a representation fingerprint and strong HTTP validator, never a CDN URL.
struct OfflinePieces {
  static let span: Int64 = 4 * 1024 * 1024
  struct State: Codable, Equatable {
    let identity: String, validator: String, total: Int64, committed: Int64
  }
  struct Slice: Sendable {
    let start: Int64, length: Int64, total: Int64, validator: String?
    init?(range: String?, requested: String?, expected: Int64, etag: String?) {
      guard let parsed = MediaRange(field: range, request: requested, declared: expected),
        parsed.total <= 512 * 1024 * 1024 * 1024,
        let request = requested, let wanted = RelayRange(request, length: parsed.total),
        parsed.length > 0, parsed.length <= OfflinePieces.span
      else { return nil }
      start = wanted.first
      total = parsed.total
      length = parsed.length
      validator = OfflinePieces.strong(etag)
    }
  }
  enum Failure: Error { case changed, invalid }
  enum Advance { case more, complete, whole }
  let base: URL, identity: String
  let legacy: Bool
  var receipt: URL { base.appendingPathExtension("resume.json") }
  var partial: URL { base.appendingPathExtension("partial") }
  init(base: URL, identity: String, legacy: Bool = false) {
    self.base = base
    self.identity = identity
    self.legacy = legacy
  }
  static func strong(_ raw: String?) -> String? {
    guard let s = raw, s.utf8.count > 2, s.utf8.count <= 256, s.first == "\"", s.last == "\"",
      s.dropFirst().dropLast().utf8.allSatisfy({ $0 >= 33 && $0 != 34 && $0 < 127 })
    else { return nil }
    return s
  }
  func state() -> State? {
    guard let b = try? Data(contentsOf: receipt), b.count < 1024,
      let st = try? JSONDecoder().decode(State.self, from: b), st.identity == identity,
      Self.strong(st.validator) != nil,
      st.committed > 0, st.committed <= st.total, st.total <= 512 * 1024 * 1024 * 1024,
      let length = (try? partial.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])),
      length.isSymbolicLink != true,
      let n = length.fileSize, Int64(n) >= st.committed
    else { return nil }
    return st
  }
  func request(_ st: State?) -> String {
    let n = st?.committed ?? 0
    return "bytes=\(n)-\(min(n+Self.span-1,(st?.total ?? Int64.max)-1))"
  }
  func clear() throws {
    for f in [receipt, partial] where FileManager.default.fileExists(atPath: f.path) {
      try FileManager.default.removeItem(at: f)
    }
  }
  func accept(_ chunk: URL, _ slice: Slice) throws -> Advance {
    let size = try chunk.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
    guard size.isSymbolicLink != true, let size = size.fileSize, Int64(size) == slice.length else {
      throw Failure.invalid
    }
    if slice.start == 0 && slice.length == slice.total {
      try Self.requireHeader(chunk, legacy: legacy)
      try clear()
      try FileManager.default.moveItem(at: chunk, to: partial)
      return .complete
    }
    guard let etag = slice.validator else {
      if slice.start == 0 {
        try clear()
        return .whole
      }
      throw Failure.changed
    }
    let st = state()
    if slice.start == 0 {
      try Self.requireHeader(chunk, legacy: legacy)
      try clear()
      try FileManager.default.moveItem(at: chunk, to: partial)
    } else {
      guard let st, st.committed == slice.start, st.total == slice.total, st.validator == etag
      else { throw Failure.changed }
      let out = try FileHandle(forWritingTo: partial)
      defer { try? out.close() }
      // If the process died after writing but before publishing the receipt, drop that tail first.
      try out.truncate(atOffset: UInt64(st.committed))
      try out.seekToEnd()
      let input = try FileHandle(forReadingFrom: chunk)
      defer { try? input.close() }
      while let data = try input.read(upToCount: 256 * 1024), !data.isEmpty {
        try Task.checkCancellation()
        try out.write(contentsOf: data)
      }
      try out.synchronize()
    }
    let end = slice.start + slice.length
    try JSONEncoder().encode(
      State(identity: identity, validator: etag, total: slice.total, committed: end)
    ).write(to: receipt, options: .atomic)
    return end == slice.total ? .complete : .more
  }
  static func requireHeader(_ url: URL, legacy: Bool = false) throws {
    let h = try FileHandle(forReadingFrom: url)
    defer { try? h.close() }
    guard let d = try h.read(upToCount: 64), d.range(of: Data("ftyp".utf8)) != nil || (legacy && d.starts(with: [0x46, 0x4c, 0x56])) else {
      throw Failure.invalid
    }
  }
}
actor OfflinePieceWriter {
  static let shared = OfflinePieceWriter()
  func accept(_ work: OfflinePieces, _ chunk: URL, slice: OfflinePieces.Slice) throws
    -> OfflinePieces.Advance
  { try work.accept(chunk, slice) }
  func clear(_ work: OfflinePieces) throws { try work.clear() }
}
