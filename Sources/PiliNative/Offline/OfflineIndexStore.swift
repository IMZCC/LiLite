import Foundation

enum OfflineIndexStore {
  private static let cap = 64 * 1024 * 1024
  struct Result { let rows: [OfflineVideo], recovered: Bool }
  static func backup(_ index: URL) -> URL {
    index.deletingLastPathComponent().appendingPathComponent("index.recovery.json")
  }
  private static func bytes(_ url: URL) throws -> Data {
    let f = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
    guard f.isRegularFile == true, f.isSymbolicLink != true, let n = f.fileSize, n <= cap else {
      throw ServiceError("缓存清单不可读")
    }
    return try Data(contentsOf: url)
  }
  static func load(_ index: URL) throws -> Result {
    let fm = FileManager.default
    let backup = backup(index)
    let exists = fm.fileExists(atPath: index.path)
    if !exists && !fm.fileExists(atPath: backup.path) { return .init(rows: [], recovered: false) }
    if exists, let raw = try? bytes(index),
      let rows = try? JSONDecoder().decode([OfflineVideo].self, from: raw)
    {
      return .init(rows: rows, recovered: false)
    }
    if exists {
      // Preserve the exact damaged source before replacing either index.
      let file = index.deletingLastPathComponent().appendingPathComponent(
        "index.damaged." + UUID().uuidString + ".json")
      try fm.copyItem(at: index, to: file)
    }
    if let raw = try? bytes(backup),
      let rows = try? JSONDecoder().decode([OfflineVideo].self, from: raw)
    {
      return .init(rows: rows, recovered: true)
    }
    struct Lossy: Decodable {
      let row: OfflineVideo?
      init(from d: Decoder) throws { row = try? OfflineVideo(from: d) }
    }
    if let raw = try? bytes(index),
      let decoded = try? JSONDecoder().decode([Lossy].self, from: raw),
      !decoded.compactMap(\.row).isEmpty
    {
      return .init(rows: decoded.compactMap(\.row), recovered: true)
    }
    throw ServiceError("缓存清单无法读取，原文件已保留")
  }
  static func save(_ rows: [OfflineVideo], _ index: URL) throws {
    let data = try JSONEncoder().encode(rows)
    guard data.count <= cap else { throw ServiceError("缓存清单过大") }
    try data.write(to: index, options: .atomic)
    try data.write(to: backup(index), options: .atomic)
  }
}
