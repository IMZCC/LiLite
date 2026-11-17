import Foundation

struct MobileFeed: Decodable {
  struct Entry: Decodable {
    let video: Video?
    enum K: String, CodingKey {
      case three_point_v2, uri, bvid, title, cover, card_goto, can_play, ad_info, param,
        player_args, args, rcmd_reason, desc_button, cover_left_text_1, cover_left_text_2, stat
    }
    struct Player: Decodable { let aid: ServiceID?, cid: ServiceID?, duration: Int? }
    struct Args: Decodable { let up_id: ServiceID?, up_name: String?, tname: String? }
    struct Caption: Decodable { let text: String? }
    init(from decoder: Decoder) throws {
      guard let c = try? decoder.container(keyedBy: K.self),
        (try? c.decode(Int.self, forKey: .can_play)) == 1,
        !c.contains(.ad_info) || (try? c.decodeNil(forKey: .ad_info)) == true,
        let goto = try? c.decode(String.self, forKey: .card_goto), !goto.hasPrefix("ad_"),
        let title = try? c.decode(String.self, forKey: .title), !title.isEmpty
      else {
        video = nil
        return
      }
      let p = try? c.decode(Player.self, forKey: .player_args)
      let args = try? c.decode(Args.self, forKey: .args)
      let param = (try? c.decode(ServiceID.self, forKey: .param))?.number
      let aid = p?.aid?.number ?? (["av", "vertical_av"].contains(goto) ? param : nil)
      let uri = try? c.decode(String.self, forKey: .uri)
      let dest = uri.flatMap(SharedLink.parse)
      let raw = try? c.decode(String.self, forKey: .bvid)
      guard
        let id = raw.flatMap({ ArchiveNumber.av($0) != nil ? $0 : nil }) ?? aid.flatMap(
          ArchiveNumber.bv) ?? (dest != nil ? uri : nil)
      else {
        video = nil
        return
      }
      let reason = try? c.decode(String.self, forKey: .rcmd_reason)
      let followed = ["已关注", "新关注"].contains(reason ?? "")
      let desc = (try? c.decode(Caption.self, forKey: .desc_button))?.text
      let own = Video.Owner(
        mid: args?.up_id?.number, name: goto == "av" ? args?.up_name : (desc ?? args?.up_name))
      let v = (try? c.decode(Video.Stat.self, forKey: .stat))
      let stats = Video.Stat(
        like: v?.like,
        view: v?.view
          ?? (try? c.decode(String.self, forKey: .cover_left_text_1)).flatMap(MobileFeed.count),
        danmaku: v?.danmaku
          ?? (try? c.decode(String.self, forKey: .cover_left_text_2)).flatMap(MobileFeed.count))
      var row = Video(
        bvid: id, title: title, pic: (try? c.decode(String.self, forKey: .cover)) ?? "", owner: own,
        stat: stats, duration: p?.duration, desc: nil, cid: p?.cid?.number, pages: nil)
      row.aid = aid ?? ArchiveNumber.av(id)
      row.is_followed = followed ? 1 : 0
      row.tname = args?.tname
      if !followed, reason != "竖屏" { row.recommendationReason = reason }
      row.recommendLink = dest == nil ? nil : uri
      row.recommendGoto = goto
      row.recommendResource = param
      row.recommendMenu = try? c.decode([Video.FeedMenu].self, forKey: .three_point_v2)
      video = row
    }
  }
  let items: [Entry]
  static func count(_ text: String) -> Int? {
    var s = text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(
      of: ",", with: "")
    let factor: Double
    if s.hasSuffix("亿") {
      factor = 100_000_000
      s.removeLast()
    } else if s.hasSuffix("万") {
      factor = 10000
      s.removeLast()
    } else {
      factor = 1
    }
    guard let value = Double(s), value.isFinite, value >= 0 else { return nil }
    return Int(exactly: (value * factor).rounded())
  }
  static func fields(page: Int) -> [String: String] {
    let idx = max(0, page - 1)
    return [
      "build": "8430300", "c_locale": "zh_CN", "channel": "master", "column": "2",
      "device": "phone", "device_name": "android", "device_type": "0", "disable_rcmd": "0",
      "flush": "8", "fnval": "976", "fnver": "0", "force_host": "2", "fourk": "1",
      "guidance": "1", "https_url_req": "1", "idx": String(idx), "mobi_app": "android_i",
      "network": "wifi", "platform": "android", "player_net": "1",
      "pull": idx == 0 ? "true" : "false", "qn": "32", "recsys_mode": "0",
      "s_locale": "zh_CN", "splash_id": "", "voice_balance": "0",
      "statistics": #"{"appId":1,"platform":3,"version":"8.43.0","abtest":""}"#,
    ]
  }
}
