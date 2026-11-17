import CoreFoundation
import Foundation

struct LiveRoom: Decodable, Identifiable {
  let roomid: Int64, title: String
  let uname: String?, cover: String?, user_cover: String?, system_cover: String?
  let feedback: [LiveFeedbackGroup]?
  var page = 1
  var viewer: String?
  enum CodingKeys: String, CodingKey {
    case roomid, id, title, uname, cover, user_cover, system_cover, feedback
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    roomid =
      (try? c.decode(Int64.self, forKey: .roomid)) ?? (try? c.decode(Int64.self, forKey: .id)) ?? 0
    guard roomid > 0 else {
      throw DecodingError.dataCorruptedError(
        forKey: .roomid, in: c, debugDescription: "Invalid room")
    }
    title = (try? c.decode(String.self, forKey: .title)) ?? "直播间"
    uname = try? c.decode(String.self, forKey: .uname)
    cover = try? c.decode(String.self, forKey: .cover)
    user_cover = try? c.decode(String.self, forKey: .user_cover)
    system_cover = try? c.decode(String.self, forKey: .system_cover)
    feedback = try? c.decode([LiveFeedbackGroup].self, forKey: .feedback)
  }
  var id: Int64 { roomid }
}
struct LiveFollowPage: Decodable {
  struct Row: Decodable, Identifiable {
    let roomid: Int64?, title: String?, uname: String?, live_status:Int?, room_cover:String?, area_name:String?, text_small:String?
    var id:Int64 {roomid ?? 0}
  }
  let list:[Row]?, totalPage:Int?, live_count:Int?
  var onAir:[Row] {
    var seen=Set<Int64>();return (list ?? []).filter{$0.id>0 && $0.live_status==1 && seen.insert($0.id).inserted}
  }
  func next(after page:Int, uniqueSeen:Int)->String? {
    guard page > 0, page < Int.max, live_count.map({ uniqueSeen < $0 }) ?? true, !(list ?? []).isEmpty else{return nil}
    if let totalPage { return page < totalPage ? String(page+1):nil }
    return (list?.count ?? 0) >= 9 ? String(page+1):nil
  }
}
enum LiveRoomUpdate: Equatable, Sendable {
  case watched(String), title(String), online(Int64)
  static func read(_ event:[String:Any]) -> Self? {
    guard let key=(event["cmd"] as? String)?.split(separator:":").first, let d=event["data"] as? [String:Any] else {return nil}
    if key == "ONLINE_RANK_COUNT" {
      let raw = d["count"].map { String(describing:$0) } ?? ""
      guard !raw.isEmpty, raw.utf8.allSatisfy({(48...57).contains($0)}), let n=Int64(raw),n>=0 else{return nil};return .online(n)
    }
    guard key == "WATCHED_CHANGE" || key == "ROOM_CHANGE",
      let text=d[key == "ROOM_CHANGE" ? "title":"text_large"] as? String,
      !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,text.count<=512 else{return nil}
    return key == "ROOM_CHANGE" ? .title(text):.watched(text)
  }
}

struct LiveSource: Decodable {
  let live_status: Int
  var live_time: Int64? = nil
  static func request(room:Int64, quality:Int, audioOnly:Bool) -> [String:String] {
    var q = ["room_id":String(room),"qn":String(quality),"protocol":"0,1","format":"0,1,2","codec":"0,1,2",
      "platform":"web","ptype":"8","panorama":"1","dolby":"5","web_location":"444.8"]
    if audioOnly { q["only_audio"] = "1" };return q
  }
  let playurl_info: PlayInfo?
  struct PlayInfo: Decodable { let playurl: Play? }
  struct Play: Decodable { let stream: [Stream] }
  struct Stream: Decodable {
    let protocol_name: String
    let format: [Format]
  }
  struct Format: Decodable {
    let format_name: String
    let codec: [Codec]
  }
  struct Codec: Decodable {
    let codec_name: String, base_url: String
    let url_info: [Host]
    let current_qn: Int
    let accept_qn: [Int]?
  }
  struct Host: Decodable { let host: String, extra: String? }

}
struct LiveLine: Identifiable, Sendable {
  let id = UUID()
  let name: String
  let text: String
  var highlight = false
  var uid: Int64? = nil
  var paidID: Int64? = nil
  var room: Int64? = nil
  var sourceID: String? = nil, timestamp: String? = nil, signature: String? = nil
  var dmType: Int? = nil, repliedName: String? = nil, medal: String? = nil
  var repliedUID: Int64? = nil
  var emote: String? = nil
  var inlineEmotes: [String: String] = [:]
  var arrived: Double? = nil, mode: Int = 1, rgb: Int = 0xffffff
}

struct LiveRoomIdentity: Decodable { let room_id, uid: Int64 }

struct LiveFeedbackGroup: Decodable {
  struct Reason: Decodable, Hashable {
    let id: Int64?, name: String?, id_type: String?
    var usable: Bool { id != nil && !(name ?? "").isEmpty && !(id_type ?? "").isEmpty }
  }
  let title, subtitle: String?
  let reasons: [Reason]?
}
struct LiveFeedCards: Decodable {
  struct Tab: Decodable, Hashable {
    let area_v2_parent_id: Int?, area_v2_id: Int?, title: String?
  }
  struct Card: Decodable {
    struct Items<T: Decodable>: Decodable { let list: [T]? }
    struct Payload: Decodable {
      let small_card_v1: LiveRoom?, my_idol_v1: Items<LiveRoom>?, area_entrance_v3: Items<Tab>?
    }
    let room: LiveRoom?, followed: [LiveRoom], areas: [Tab]
    enum Key: String, CodingKey { case card_type, card_data }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Key.self)
      let type = try? c.decode(String.self, forKey: .card_type)
      let payload = try? c.decode(Payload.self, forKey: .card_data)
      room = type == "small_card_v1" ? payload?.small_card_v1 : nil
      followed = type == "my_idol_v1" ? payload?.my_idol_v1?.list ?? [] : []
      areas = type == "area_entrance_v3" ? payload?.area_entrance_v3?.list ?? [] : []
    }
  }
  let card_list: [Card], has_more: Int?
}
extension LiveRoom {
  func feedbackFields(_ reason: LiveFeedbackGroup.Reason, owner: String) -> [String: String]? {
    guard viewer == owner, !owner.isEmpty, page > 0, reason.usable,
      let value = reason.id, let type = reason.id_type,
      feedback?.contains(where: { $0.reasons?.contains(reason) == true }) == true
    else { return nil }
    return [
      "id": String(value), "id_type": type, "room_id": String(id), "type": "dislike",
      "page": String(page),
    ]
  }
}
enum LiveReportReason: Int, CaseIterable {
  case illegal = 1
  case sexual, advertising, abusive, political, minors
  case other = 0
  var label: String {
    switch self {
    case .illegal: return "违法违规"
    case .sexual: return "低俗色情"
    case .advertising: return "垃圾广告"
    case .abusive: return "辱骂引战"
    case .political: return "政治敏感"
    case .minors: return "青少年不良信息"
    case .other: return "其他"
    }
  }
}
struct LiveReplyTarget: Equatable {
  let uid: Int64, name: String, sourceID: String, room: Int64, account: String
  func fields(room: Int64, account: String) -> [String: String]? {
    guard self.room == room, self.account == account else { return nil }
    return ["reply_mid": String(uid), "replay_dmid": sourceID]
  }
}
extension LiveLine {
  func reply(room canonical: Int64, account: String) -> LiveReplyTarget? {
    guard paidID == nil, room == canonical, let uid, uid > 0, let sourceID, !account.isEmpty else {
      return nil
    }
    return .init(uid: uid, name: name, sourceID: sourceID, room: canonical, account: account)
  }
  func reportFields(room canonical: Int64, reason: LiveReportReason) -> [String: String]? {
    guard paidID == nil, canonical > 0, room == canonical, let uid, uid > 0, let sourceID,
      let timestamp, let signature, let dmType, !text.isEmpty
    else { return nil }
    return [
      "id": "0", "roomid": String(canonical), "tuid": String(uid), "msg": text,
      "reason": reason.label, "reason_id": String(reason.rawValue), "ts": timestamp,
      "sign": signature, "token": "", "dm_type": String(dmType), "id_str": sourceID, "visit_id": "",
    ]
  }
  func copyInfo() -> String {
    var info: [String: Any] = ["name": name, "text": text]
    info["roomid"] = room
    info["uid"] = uid
    info["id_str"] = sourceID
    info["ts"] = timestamp
    info["ct"] = signature
    info["dm_type"] = dmType
    info["medal"] = medal
    info["emoticon"] = emote
    if !inlineEmotes.isEmpty { info["emots"] = inlineEmotes }
    info["reply_mid"] = repliedUID
    info["reply_uname"] = repliedName
    return
      (try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]))
      .map { String(decoding: $0, as: UTF8.self) } ?? text
  }
}
enum LiveMessageSource {
  typealias Map = [String: Any]
  private static func scalar(_ value: Any?) -> String? {
    if let s = value as? String, !s.isEmpty { return s }
    guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
      !["f", "d"].contains(String(cString: n.objCType))
    else { return nil }
    return n.stringValue
  }
  private static func pos(_ v: Any?) -> Int64? {
    scalar(v).flatMap(Int64.init).flatMap { $0 > 0 ? $0 : nil }
  }
  private static func info(_ v: Any?) -> Map {
    if let d = v as? Map { return d }
    if let s = v as? String, s.utf8.count <= 512 * 1024,
      let d = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? Map
    {
      return d
    }
    return [:]
  }
  private static func make(
    room: Int64, text: String, user: Map, legacyID: Any?, legacyName: Any?,
    data: Map, check: Map, reply: Map, emote: Map
  ) -> LiveLine {
    let structured = pos(user["uid"])
    let legacy = pos(legacyID)
    let nestedName = ((user["base"] as? Map)?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let name: String
    if let structured {
      name =
        nestedName ?? (legacy == structured ? legacyName as? String : nil) ?? "UID "
        + String(structured)
    } else {
      name = legacyName as? String ?? nestedName ?? ""
    }
    var line = LiveLine(name: name, text: text, uid: structured ?? legacy, room: room)
    if let structured, legacy == nil || legacy == structured {
      line.sourceID = scalar(data["id_str"]).flatMap {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || $0 == "0" ? nil : $0
      }
      line.timestamp = pos(check["ts"]) == nil ? nil : scalar(check["ts"])
      line.signature = (check["ct"] as? String).flatMap {
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0
      }
      line.dmType = scalar(data["dm_type"]).flatMap(Int.init).flatMap { $0 >= 0 ? $0 : nil }
    }
    if let id = pos(reply["reply_mid"]) {
      line.repliedUID = id
      line.repliedName =
        (reply["reply_uname"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(id)
    }
    if let medal = user["medal"] as? Map, scalar(medal["is_light"]) == "1",
      let label = medal["name"] as? String, !label.isEmpty
    {
      line.medal = label + (pos(medal["level"]).map { " \($0)" } ?? "")
    }
    line.emote = emote["url"] as? String
    line.inlineEmotes = (data["emots"] as? Map ?? [:]).compactMapValues {
      ($0 as? Map)?["url"] as? String
    }
    return line
  }
  static func history(_ data: Data, room: Int64) throws -> [LiveLine] {
    guard room > 0, let result = try JSONSerialization.jsonObject(with: data) as? Map,
      scalar(result["code"]) == "0", let rows = (result["data"] as? Map)?["room"] as? [Any]
    else {
      throw ServiceError("无法读取直播弹幕")
    }
    return rows.compactMap {
      guard let row = $0 as? Map, let text = row["text"] as? String, !text.isEmpty else {
        return nil
      }
      return make(
        room: room, text: text, user: info(row["user"]), legacyID: row["uid"],
        legacyName: row["nickname"], data: row, check: info(row["check_info"]),
        reply: info(row["reply"]),
        emote: info(row["emoticon"]))
    }
  }
  static func socket(_ info: [Any], room: Int64) -> LiveLine? {
    guard room > 0, info.count > 2, let text = info[1] as? String, !text.isEmpty else { return nil }
    let first = info[0] as? [Any] ?? []
    let legacy = info[2] as? [Any] ?? []
    let body = first.indices.contains(15) ? self.info(first[15]) : [:]
    let extra = self.info(body["extra"])
    var line = make(
      room: room, text: text, user: self.info(body["user"]), legacyID: legacy.first,
      legacyName: legacy.dropFirst().first, data: extra,
      check: info.indices.contains(9) ? self.info(info[9]) : [:],
      reply: extra, emote: first.indices.contains(13) ? self.info(first[13]) : [:])
    line.arrived = ProcessInfo.processInfo.systemUptime
    if let mode = scalar(extra["mode"]).flatMap(Int.init), [1, 4, 5, 6].contains(mode) {
      line.mode = mode
    }
    if let color = scalar(extra["color"]).flatMap(Int.init), (0...0xffffff).contains(color) {
      line.rgb = color
    }
    return line
  }
}

struct LiveLikeCounter {
  private(set) var taps = 0
  mutating func tap() { if taps < Int.max { taps += 1 } }
  mutating func take() -> Int {
    defer { taps = 0 }
    return taps
  }
}
extension LiveRoomIdentity {
  func likeFields(taps: Int, owner: String, csrf: String) -> [String: String]? {
    guard taps > 0, room_id > 0, uid > 0, (Int64(owner) ?? 0) > 0, !csrf.isEmpty else { return nil }
    return [
      "click_time": String(taps), "room_id": String(room_id), "uid": owner,
      "anchor_id": String(uid),
      "web_location": "444.8", "csrf": csrf,
    ]
  }
}
