import Foundation

enum SearchHistoryStore {
  private static let key = "search.history"
  static let importLimit = 8 * 1024 * 1024
  enum Change: Sendable { case record(String), remove(String), replace(Data), clear }
  @MainActor private static var writer: Task<Void, Never>?
  @MainActor private static var last: UUID?

  static func preview(_ bytes: Data) -> [String] {
    guard let words = try? JSONDecoder().decode([String].self, from: bytes) else { return [] }
    var seen = Set<String>(), result = [String]()
    for word in words where !word.isEmpty && seen.insert(word).inserted {
      result.append(word)
      if result.count == 20 { break }
    }
    return result
  }
  static func edit(_ change: Change, original: Data?) throws -> Data? {
    func words() throws -> [String] {
      guard let original, !original.isEmpty else { return [] }
      return try JSONDecoder().decode([String].self, from: original)
    }
    switch change {
    case .clear: return nil
    case .record(let term): return try JSONEncoder().encode([term] + words().filter { $0 != term })
    case .remove(let term): return try JSONEncoder().encode(words().filter { $0 != term })
    case .replace(let bytes):
      guard bytes.count <= importLimit, let all = try? JSONDecoder().decode([String].self, from: bytes)
      else { throw ServiceError("请选择搜索历史的 JSON 字符串列表") }
      var seen = Set<String>()
      return try JSONEncoder().encode(all.filter { !$0.isEmpty && seen.insert($0).inserted })
    }
  }
  // Preserve tap order across search views; JSON work never runs on the UI actor. A backup
  // restoration or settings reset made during that work owns the newer preference.
  @MainActor static func enqueue(_ change: Change, failure: @escaping @MainActor (Error) -> Void) {
    let previous = writer, id = UUID()
    last = id
    writer = Task {
      await previous?.value
      let d = UserDefaults.standard, original = d.data(forKey: key)
      do {
        let data = try await Task.detached(priority: .userInitiated) { try edit(change, original: original) }.value
        if original == d.data(forKey: key) {
          if let data { d.set(data, forKey: key) } else { d.removeObject(forKey: key) }
        }
      } catch { failure(error) }
      if last == id { writer = nil; last = nil }
    }
  }
  @MainActor static func snapshot() async -> Data {
    await writer?.value
    let data = UserDefaults.standard.data(forKey: key)
    return data.flatMap { $0.isEmpty ? nil : $0 } ?? Data("[]".utf8)
  }
}
