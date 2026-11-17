import Foundation

struct EpisodeCachePolicy {
  typealias Map = [String: Any]
  static func flag(_ value: Any?) -> Bool? {
    if let n = value as? NSNumber { return n.intValue != 0 }
    if let s = value as? String {
      if ["1", "true"].contains(s.lowercased()) { return true }
      if ["0", "false"].contains(s.lowercased()) { return false }
    }
    return nil
  }
  static func episodeID(_ row: Map, course: Bool) -> Int64? {
    let keys = course ? ["id"] : ["ep_id", "id"]
    return keys.lazy.compactMap { k in
      ((row[k] as? NSNumber)?.int64Value ?? (row[k] as? String).flatMap(Int64.init)).flatMap {
        $0 > 0 ? $0 : nil
      }
    }.first
  }
  private static func downloadGrant(_ raw: Any?) -> Bool? {
    guard let raw, !(raw is NSNull) else { return nil }
    if let n = raw as? NSNumber { return n.doubleValue == 1 }
    if let s = raw as? String { return ["1", "true"].contains(s.lowercased()) }
    return false
  }
  static func allow(series: Map, episode: Map, vip: Bool) throws {
    let outer = series["rights"] as? Map ?? [:]
    let inner = episode["rights"] as? Map ?? [:]
    let instructions = [
      downloadGrant(outer["allow_download"]), downloadGrant(inner["allow_download"]),
      downloadGrant(series["allow_download"]),
      downloadGrant(episode["allow_download"]),
    ].compactMap { $0 }
    guard instructions.contains(true), !instructions.contains(false),
      flag(outer["area_limit"]) != true, flag(inner["area_limit"]) != true,
      flag(outer["can_watch"]) != false, flag(inner["can_watch"]) != false,
      flag(series["playable"]) != false, flag(episode["playable"]) != false,
      [outer, inner, series, episode].allSatisfy({ flag($0["is_preview"]) != true }),
      !(flag(outer["only_vip_download"]) == true || flag(inner["only_vip_download"]) == true) || vip
    else { throw ServiceError("当前账号没有这一集的离线缓存权限") }
  }
  static func denial(_ data: Map) -> String? {
    guard let r = data["not_playable_reason"] as? Map, !r.isEmpty else { return nil }
    let message = (r["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let code = (r["code"] as? NSNumber)?.intValue ?? (r["code"] as? String).flatMap(Int.init)
    if code == 0 && message.isEmpty { return nil }
    return message.isEmpty ? "当前账号不可播放" : message
  }
  static func previewMedia(_ m: Map) -> Bool {
    flag(m["is_preview"]) == true
      || (m["accept_description"] as? [String] ?? []).contains { $0.contains("试看") }
  }
  static func clearPayload(_ data: Map) throws -> Map {
    let info = data["video_info"] as? Map ?? data
    var arc = data["arc"] as? Map ?? [:]
    arc["is_drm"] = nil
    func protected(_ row: Map) -> Bool {
      ["is_drm", "is_preview", "drm_tech_type", "drm_type"].contains { flag(row[$0]) == true }
        || ["content_protection", "drm_info", "pssh", "license_url"].contains { key in
          if let s = row[key] as? String { return !s.isEmpty }
          if let map = row[key] as? Map { return !map.isEmpty }
          if let a = row[key] as? [Any] { return !a.isEmpty }
          return false
        }
    }
    guard denial(data) == nil, denial(info) == nil, !previewMedia(data), !previewMedia(info),
      !protected(data),
      !protected(arc), !protected(info), !(info["durl"] as? [Map] ?? []).contains(where: protected)
    else { throw ServiceError("该媒体不支持本机离线缓存") }
    guard let dash = info["dash"] as? Map else {
      guard let durl = info["durl"] as? [Map], !durl.isEmpty, !durl.contains(where: protected) else { throw ServiceError("该媒体不支持本机离线缓存") }
      return info
    }
    guard !protected(dash) else { throw ServiceError("该媒体不支持本机离线缓存") }
    for type in ["video", "audio"] {
      if (dash[type] as? [Map] ?? []).contains(where: protected) {
        throw ServiceError("该媒体不支持本机离线缓存")
      }
    }
    let dolby = (dash["dolby"] as? Map)?["audio"] as? [Map] ?? []
    let flac = (dash["flac"] as? Map)?["audio"] as? Map
    guard !dolby.contains(where: protected), flac.map(protected) != true else {
      throw ServiceError("该媒体不支持本机离线缓存")
    }
    return info
  }
  static func clearMedia(_ data: Map) throws -> Map {
    let info = try clearPayload(data)
    guard let dash = info["dash"] as? Map else { throw ServiceError("该媒体没有分轨播放地址") }
    return dash
  }
}
