import Foundation

enum SuperChatDisplay: Int, CaseIterable {
  case current, persistent, hidden
  var title: String {
    switch self {
    case .current: return "有效期内显示"
    case .persistent: return "常驻显示"
    case .hidden: return "不显示"
    }
  }
}
struct SuperChatMessage: Decodable, Identifiable, Sendable {
  let id, uid: Int64
  let price: Int
  let start, end: Int64
  let timestamp: Int64?
  let text, name: String
  let token, face, medal, frame, background: String?
  let medalLevel: Int?
  let topColor, bottomColor, priceColor, textColor, nameColor: String
  enum Key: String, CodingKey {
    case id, uid, price, start_time, end_time, message, token, ts, user_info, uinfo, medal_info,
      background_image, background_color, background_bottom_color, background_price_color,
      message_font_color
  }
  struct User: Decodable {
    let uname: String?, face: String?, face_frame: String?, name_color: String?
  }
  struct Medal: Decodable { let name: String?, medal_name: String?, level: Int?, medal_level: Int? }
  struct Info: Decodable { let medal: Medal? }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    func num(_ key: Key) -> Int64? { (try? c.decode(ServiceID.self, forKey: key))?.number }
    func string(_ key: Key) -> String? { try? c.decode(String.self, forKey: key) }
    guard let identifier = num(.id), identifier > 0, let owner = num(.uid), owner > 0,
      let begin = num(.start_time), begin >= 0, let finish = num(.end_time), finish >= begin,
      let amount = num(.price).flatMap(Int.init(exactly:)), amount >= 0,
      let body = string(.message), !body.isEmpty
    else { throw ServiceError("醒目留言格式无效") }
    id = identifier
    uid = owner
    price = amount
    start = begin
    end = finish
    text = body
    timestamp = num(.ts)
    token = string(.token)
    let user = try? c.decode(User.self, forKey: .user_info)
    name = user?.uname ?? "UID \(owner)"
    face = user?.face
    frame = user?.face_frame
    background = string(.background_image)
    nameColor = user?.name_color ?? "#666666"
    let badge =
      (try? c.decode(Info.self, forKey: .uinfo))?.medal
      ?? (try? c.decode(Medal.self, forKey: .medal_info))
    medal = badge?.name ?? badge?.medal_name
    medalLevel = badge?.level ?? badge?.medal_level
    topColor = string(.background_color) ?? "#EDF5FF"
    bottomColor = string(.background_bottom_color) ?? "#2A60B2"
    priceColor = string(.background_price_color) ?? "#7497CD"
    textColor = string(.message_font_color) ?? "#FFFFFF"
  }
  func copyInfo(room: Int64) throws -> Data {
    let user: [String: Any] = [
      "uname": name, "face": face ?? "", "face_frame": frame as Any? ?? NSNull(),
      "name_color": nameColor,
    ]
    var o: [String: Any] = [
      "id": id, "uid": uid, "price": price, "roomid": room, "message": text, "start_time": start,
      "end_time": end,
      "user_info": user, "background_color": topColor,
      "background_bottom_color": bottomColor,
      "background_price_color": priceColor, "message_font_color": textColor,
    ]
    o["ts"] = timestamp
    o["background_image"] = background
    o["token"] = token
    if let medal { o["uinfo"] = ["medal": ["name": medal, "level": medalLevel ?? 0]] }
    return try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys])
  }
  var reportable: Bool { (timestamp ?? 0) > 0 && !(token ?? "").isEmpty }
  func reportFields(room: Int64, label: String) -> [String: String]? {
    guard room > 0, reportable, let token, let timestamp else { return nil }
    return [
      "id": String(id), "id_str": String(id), "roomid": String(room), "uid": String(uid),
      "msg": text,
      "reason": label, "reason_id": label, "ts": String(timestamp), "sign": "", "token": token,
      "visit_id": "",
    ]
  }
  func active(at time: Int64) -> Bool { start <= time && time < end }
}
struct SuperChatSnapshot: Decodable {
  let items: [SuperChatMessage]
  enum Key: String, CodingKey { case list }
  struct Row: Decodable {
    let item: SuperChatMessage?
    init(from decoder: Decoder) throws { item = try? SuperChatMessage(from: decoder) }
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Key.self)
    items = try c.decodeIfPresent([Row].self, forKey: .list)?.compactMap(\.item) ?? []
  }
}
enum SuperChatEvent: Sendable {
  case add(SuperChatMessage)
  case remove([Int64])
  static func parse(_ body: Data, command: String) -> Self? {
    struct Added: Decodable { let data: SuperChatMessage }
    struct Deletion: Decodable {
      struct Value: Decodable { let ids: [ServiceID] }
      let data: Value
    }
    switch command {
    case "SUPER_CHAT_MESSAGE", "SUPER_CHAT_MESSAGE_JPN":
      return (try? JSONDecoder().decode(Added.self, from: body)).map { .add($0.data) }
    case "SUPER_CHAT_MESSAGE_DELETE":
      return (try? JSONDecoder().decode(Deletion.self, from: body)).map {
        .remove($0.data.ids.compactMap(\.number))
      }
    default: return nil
    }
  }
}
struct SuperChatLedger {
  private(set) var items: [SuperChatMessage] = []
  private var deleted = Set<Int64>()
  private(set) var featured: (id: Int64, until: Int64)?
  mutating func seed(_ batch: [SuperChatMessage]) {
    var seen = Set(items.map(\.id))
    let added = batch.filter { !deleted.contains($0.id) && seen.insert($0.id).inserted }
    items.append(contentsOf: added)
    sort()
  }
  @discardableResult mutating func accept(_ event: SuperChatEvent, now: Int64, fullscreen: Bool)
    -> SuperChatMessage?
  {
    switch event {
    case .add(let m):
      guard !deleted.contains(m.id) else { return nil }
      let existing = items.firstIndex { $0.id == m.id }
      if let existing { items[existing] = m } else { items.append(m) }
      sort()
      if fullscreen, existing == nil, m.active(at: now) { featured = (m.id, min(m.end, now + 10)) }
      return existing == nil ? m : nil
    case .remove(let ids):
      let gone = Set(ids)
      deleted.formUnion(gone)
      items.removeAll { gone.contains($0.id) }
      if let featured, gone.contains(featured.id) { self.featured = nil }
      return nil
    }
  }
  private mutating func sort() {
    items.sort { $0.start == $1.start ? $0.id > $1.id : $0.start > $1.start }
  }
  func visible(mode: SuperChatDisplay, at now: Int64) -> [SuperChatMessage] {
    switch mode {
    case .hidden: return []
    case .persistent: return items
    case .current: return items.filter { $0.active(at: now) }
    }
  }
  func overlay(at now: Int64) -> SuperChatMessage? {
    guard let featured, now < featured.until else { return nil }
    return items.first { $0.id == featured.id && $0.active(at: now) }
  }
  mutating func trimExpired(at now: Int64) {
    items.removeAll { $0.end <= now }
    if let featured, featured.until <= now { self.featured = nil }
  }
  mutating func dismissOverlay() { featured = nil }
}
