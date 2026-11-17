import Foundation

struct ServiceWatchPoint: Decodable {
  let last_play_cid: Int64?, last_play_time: Int64?
}
struct ArchiveStart {
  let cid: Int64
  var seconds: Double?
  static func offer(_ parts:[Video.Part],current:Int64?,enabled:Bool,local:Int64?,remote:ServiceWatchPoint?,keepTime:Bool)->Self?{
    guard enabled,parts.count>1,let current,let result=select(parts,fallback:nil,page:nil,from:nil,continuePart:true,local:local,remote:remote,saveTime:keepTime),result.cid != current else{return nil}
    return result
  }
  static func select(
    _ parts: [Video.Part], fallback: Int64?, page: Int?, from linkSeconds: Double?,
    continuePart: Bool, local: Int64?, remote: ServiceWatchPoint?, saveTime: Bool
  ) -> Self? {
    let first = parts.first?.cid ?? fallback
    let remembered = [remote?.last_play_cid, local].compactMap { $0 }.first { candidate in
      parts.contains { $0.cid == candidate }
    }
    guard
      let cid = page.flatMap({ p in parts.first { $0.page == p }?.cid })
        ?? ((page == nil && linkSeconds == nil && continuePart) ? remembered : nil) ?? first,
      cid > 0
    else { return nil }
    if let t = linkSeconds, t.isFinite, t >= 0 { return Self(cid: cid, seconds: t) }
    let t = remote?.last_play_time.flatMap { $0 > 0 ? Double($0) / 1000 : nil }
    return Self(cid: cid, seconds: saveTime && remote?.last_play_cid == cid ? t : nil)
  }
}
@MainActor enum LastArchivePart {
  struct Mark: Codable { let cid: Int64, date: Date }
  private static let storage = "play.lastArchiveParts"
  private static var map: [String: Mark] =
    UserDefaults.standard.data(forKey: storage).flatMap {
      try? JSONDecoder().decode([String: Mark].self, from: $0)
    } ?? [:]
  static func key(_ bvid: String, uid: String?) -> String { "\(uid ?? "guest"):\(bvid)" }
  static func forgetStoredParts() { map.removeAll(); UserDefaults.standard.removeObject(forKey:storage) }
  static func recall(_ key: String) -> Int64? { PlaybackMemory.enabled ? map[key]?.cid : nil }
  static func played(_ key: String, cid: Int64) {
    guard PlaybackMemory.enabled, map[key]?.cid != cid else { return }
    map[key] = Mark(cid: cid, date: Date())
    if map.count > 600 {
      for (k, _) in map.sorted(by: { $0.value.date < $1.value.date }).prefix(60) { map[k] = nil }
    }
    if let data = try? JSONEncoder().encode(map) {
      UserDefaults.standard.set(data, forKey: storage)
    }
  }
}
