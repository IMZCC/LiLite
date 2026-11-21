import Foundation
import UIKit

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
      // The mobile feed has no like count; like the original, read it from a reason such as
      // "1.2万点赞" so the like-ratio filter still applies.
      let reasonLikes = reason.flatMap { $0.contains("赞") ? MobileFeed.leadingCount($0) : nil }
      let stats = Video.Stat(
        like: v?.like ?? reasonLikes,
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
      row.recommendationOpensVideo = dest?.opensVideoDetail
      row.recommendGoto = goto
      row.recommendResource = param
      row.recommendMenu = try? c.decode([Video.FeedMenu].self, forKey: .three_point_v2)
      video = row
    }
  }
  let items: [Entry]
  /// The original's `NumUtils.parseNum`: the first number in the text with an optional 千/万/亿
  /// unit, or 0 when there is none.
  static func leadingCount(_ text: String) -> Int {
    guard let m = text.firstMatch(of: #/([\d.]+)([千万亿])?/#), let value = Double(m.1),
      value.isFinite
    else { return 0 }
    let unit: Double
    switch m.2.map(String.init) ?? "" {
    case "千": unit = 1000
    case "万": unit = 10000
    case "亿": unit = 100_000_000
    default: unit = 1
    }
    return Int(exactly: (value * unit).rounded(.towardZero)) ?? 0
  }
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
  /// The official Android client's (粉版 9.19.0) home feed request, as captured in PiliPlus PR
  /// #3646. The old `mobi_app=android_i` / 8.43.0 set asked for the international client's feed,
  /// which is why recommendations did not match the official app. Signing keeps the HD key: this
  /// endpoint does not check it, and the account's access key was issued to it.
  /// `login_event` (2 signed in, 1 guest) is set by `MobileREST.request`, which knows whether the
  /// recommendation account sends an access key.
  static func fields(page: Int, screen: (short: Int, long: Int)) -> [String: String] {
    let idx = max(0, page - 1)
    return [
      "build": "9190400", "c_locale": "zh-Hans_CN", "channel": "bili", "column": "2",
      "device_name": deviceName, "device_type": "0", "disable_rcmd": "0",
      "flush": "0", "fnval": "272", "fnver": "0", "force_host": "0", "fourk": "0",
      "guidance": "0", "https_url_req": "0", "idx": String(idx), "mobi_app": "android",
      "network": "mobile", "platform": "android", "player_net": "2",
      "pull": idx == 0 ? "true" : "false", "qn": "32", "recsys_mode": "0",
      "s_locale": "zh-Hans_CN", "voice_balance": "1",
      "statistics": #"{"appId":1,"platform":3,"version":"9.19.0","abtest":""}"#,
      "auto_refresh_state": "1", "autoplay_card": "11", "autoplay_timestamp": "0", "client_attr": "0",
      "cny_info": #"{"cny_active":0,"ab_test_vars":{},"cny_interest_attach":""}"#, "column_timestamp": "0",
      "inline_danmu": "2", "inline_sound": "1", "inline_sound_cold_state": "2", "interest_id": "0",
      "login_event": "1", "open_event": "cold",
      "player_extra_content": #"{"short_edge":"\#(screen.short)","long_edge":"\#(screen.long)","cur_language":""}"#,
      "qn_policy": "1", "raw_window_size_type": "1", "soft_fnval": "0", "splash_creative_id": "0",
      "video_mode": "1", "volume_balance": "1", "window_size_type": "1",
    ]
  }
  /// The official client sends the hardware model; here that is `utsname.machine` (iPhone16,2).
  static let deviceName: String = {
    var info = utsname()
    uname(&info)
    let model = withUnsafeBytes(of: &info.machine) { raw in
      String(decoding: raw.prefix(while: { $0 != 0 }), as: UTF8.self)
    }
    return model.isEmpty ? "android" : model
  }()
  /// The screen's short and long edge in pixels, as the official client reports its display.
  @MainActor static func screenEdges() -> (short: Int, long: Int) {
    let size = UIScreen.main.nativeBounds.size
    let edges = (Int(min(size.width, size.height)), Int(max(size.width, size.height)))
    return edges.0 > 0 ? edges : (1080, 2400)
  }
  static let userAgent =
    "Mozilla/5.0 BiliDroid/9.19.0 (bbcallen@gmail.com) os/android model/android mobi_app/android build/9190400 channel/bili innerVer/9190410 osVer/15 network/1"
}
