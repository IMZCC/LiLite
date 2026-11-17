import Foundation

enum LiveSearchScope: String, CaseIterable {
  case room = "直播间"
  case host = "主播"
  var service: String { self == .room ? "live_room" : "live_user" }
}
struct LiveSearchPayload: Decodable {
  let result: [Hit]?, numPages: Int?, numResults: Int?, v_voucher: String?
  struct Hit: Decodable, Identifiable {
    let room: Int64?, uid: Int64?, name: String, title: String, picture: String?, face: String?,
      area: String?, fans: Int?, audience: Int?, live: Bool?
    var id: String { room.map { "r:\($0)" } ?? "u:\(uid ?? 0)" }
    private enum K: String, CodingKey {
      case roomid, room_id, uid, mid, uname, name, title, cover, user_cover, face, uface, area_name,
        areaName, cate_name, attentions, fansNum, online, live_status, is_live
    }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: K.self)
      func n(_ keys: K...) -> Int64? {
        for k in keys { if let v = try? c.decode(ServiceID.self, forKey: k).number { return v } }
        return nil
      }
      func s(_ keys: K...) -> String? {
        for k in keys { if let v = try? c.decode(String.self, forKey: k), !v.isEmpty { return v } }
        return nil
      }
      func clean(_ raw: String) -> String {
        raw.replacingOccurrences(
          of: "</?em(?:\\s[^>]*)?>", with: "", options: [.regularExpression, .caseInsensitive]
        ).replacingOccurrences(of: "&amp;", with: "&")
      }
      room = n(.roomid, .room_id).flatMap { $0 > 0 ? $0 : nil }
      uid = n(.uid, .mid).flatMap { $0 > 0 ? $0 : nil }
      name = clean(s(.uname, .name) ?? "主播")
      title = clean(s(.title) ?? "")
      picture = s(.user_cover, .cover)
      face = s(.uface, .face)
      area = s(.area_name, .areaName, .cate_name)
      fans = n(.attentions, .fansNum).flatMap(Int.init(exactly:))
      audience = n(.online).flatMap(Int.init(exactly:))
      live = n(.live_status, .is_live).map { $0 == 1 }
    }
  }
  func page(scope: LiveSearchScope, number: Int, size: Int, keyword:String = "") throws -> (
    rows: [Hit], next: String?, total: Int?
  ) {
    guard v_voucher?.isEmpty != false else { throw ServiceError.searchCheck(keyword) }
    let rows = (result ?? []).filter { $0.room != nil || (scope == .host && $0.uid != nil) }
    let more =
      numPages.map { number < $0 } ?? numResults.map { number * size < $0 }
      ?? ((result?.count ?? 0) == size)
    return (rows, more ? String(number + 1) : nil, numResults)
  }
}
