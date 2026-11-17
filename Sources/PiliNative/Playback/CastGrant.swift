import Foundation

struct CastSubject: Equatable, Hashable {
  let type: Int, object: Int64, cid: Int64, title: String, quality: Int, bvid: String?
  static func archive(bvid: String, aid: Int64?, cid: Int64?, title: String, quality: Int) -> Self {
    .init(
      type: 1, object: aid ?? ArchiveNumber.av(bvid) ?? 0, cid: cid ?? 0, title: title,
      quality: quality, bvid: bvid)
  }
  static func episode(id: Int64?, cid: Int64?, title: String, quality: Int) -> Self {
    .init(type: 2, object: id ?? 0, cid: cid ?? 0, title: title, quality: quality, bvid: nil)
  }
  var valid: Bool { (type == 1 || type == 2) && object > 0 && cid > 0 }
  var reference: URL? {
    if type == 1, let bvid, ArchiveNumber.av(bvid) == object {
      return URL(string: "https://www.bilibili.com/video/" + bvid + "/")
    }
    return type == 2
      ? URL(string: "https://www.bilibili.com/bangumi/play/ep" + String(object)) : nil
  }
  func fields(token: String?) -> [String: String] {
    var f = [
      "cid": String(cid), "object_id": String(object), "playurl_type": String(type),
      "qn": String(quality > 0 ? quality : 80), "fourk": "1", "is_proj": "1", "protocol": "0",
      "mobi_app": "android", "platform": "android",
    ]
    if let token, !token.isEmpty {
      f["access_key"] = token
      f["mobile_access_key"] = token
    }
    return f
  }
}
struct CastGrantBody: Decodable {
  struct Piece: Decodable {
    let url: String?, backup_url: [String]?, length: Int64?, size: Int64?, order: Int?
  }
  private struct Flag: Decodable {
    let yes: Bool
    init(from d: Decoder) throws {
      let c = try d.singleValueContainer()
      if let v = try? c.decode(Bool.self) {
        yes = v
      } else if let v = try? c.decode(Int.self) {
        yes = v != 0
      } else if let v = try? c.decode(String.self),
        ["0", "1", "false", "true"].contains(v.lowercased())
      {
        yes = v == "1" || v.lowercased() == "true"
      } else {
        throw CastProblem.denied
      }
    }
  }
  let quality: Int?, durl: [Piece]?
  private let is_preview: Flag?, is_drm: Flag?, is_drm_movie: Flag?, drm_type: Int?
  private let accept_description: [String]?
  func routes(guest: Bool, grant: ArchiveStreamGrant) throws -> [URL] {
    guard is_preview?.yes != true, is_drm?.yes != true, is_drm_movie?.yes != true,
      (drm_type ?? 0) == 0, !grant.preview, !grant.protected,
      grant.permits(quality ?? 0, guest: guest),
      !(accept_description ?? []).allSatisfy({ $0.contains("试看") })
        || (accept_description ?? []).isEmpty
    else { throw CastProblem.denied }
    guard let durl, durl.count == 1 else { throw ServiceError("此内容没有可投屏的完整视频") }
    let p = durl[0]
    var seen = Set<URL>()
    let urls = ([p.url].compactMap { $0 } + (p.backup_url ?? [])).compactMap { raw -> URL? in
      guard let u = URL(string: raw), ["http", "https"].contains(u.scheme?.lowercased() ?? ""), let h = u.host, !h.isEmpty,
        u.user == nil, u.password == nil, u.fragment == nil, seen.insert(u).inserted
      else { return nil }
      return u
    }
    guard !urls.isEmpty else { throw ServiceError("服务未提供投屏地址") }
    return urls
  }
}
