import Foundation

struct ReplyAuthor: Decodable {
  struct Badge: Decodable { let type: Int?, desc: String? }
  struct Card {
    let image: String, number: String, prefix: String, color: String
    /// The number's gradient fill (`fan_num_color_format`), when the card has one.
    var gradient: NumberGradient? = nil
    /// Start and end as "x,y"; colours as hex; stops in percent.
    struct NumberGradient { let start: String, end: String, colors: [String], stops: [Int64] }
  }
  let uname: String?, avatar: String?, official_verify: Badge?
  let pendant: String?, vipStatus: Int, vipType: Int
  struct Medal {
    let name: String, level: Int64, background: Int64, foreground: Int64
  }
  let card: Card?
  var medal: Medal? = nil
  /// Account level (0–6) and hard-core membership, shown as the original level mark.
  var level: Int? = nil
  var senior = false
  init(
    name: String?, avatar: String?, badge: Badge?, pendant: String?, vipStatus: Int, vipType: Int,
    card: Card?
  ) {
    uname = name
    self.avatar = avatar
    official_verify = badge
    self.pendant = pendant
    self.vipStatus = vipStatus
    self.vipType = vipType
    self.card = card
  }
  init(dynamic a: [String: Any]) {
    typealias Map = [String: Any]
    func number(_ v: Any?) -> Int? {
      (v as? NSNumber)?.intValue ?? (v as? String).flatMap(Int.init)
    }
    let v = a["vip"] as? Map
    let p = a["pendant"] as? Map
    let verify = (a["official_verify"] ?? a["official"]) as? Map
    let decorate = (a["decorate"] ?? a["decoration_card"]) as? Map
    let fan = decorate?["fan"] as? Map
    let card = (decorate?["card_url"] as? String).flatMap { url -> Card? in
      guard !url.isEmpty else { return nil }
      return Card(
        image: url, number: (fan?["num_str"] ?? fan?["num_desc"]) as? String ?? "",
        prefix: fan?["num_prefix"] as? String ?? "", color: fan?["color"] as? String ?? "")
    }
    self.init(
      name: (a["name"] ?? a["uname"]) as? String, avatar: (a["face"] ?? a["avatar"]) as? String,
      badge: number(verify?["type"]).map { Badge(type: $0, desc: verify?["desc"] as? String) },
      pendant: p?["image"] as? String, vipStatus: number(v?["status"] ?? v?["vipStatus"]) ?? 0,
      vipType: number(v?["type"] ?? v?["vipType"]) ?? 0, card: card)
  }
  enum Keys: String, CodingKey { case uname, avatar, official_verify, pendant, vip }
  private enum Pendant: String, CodingKey { case image }
  private enum VIP: String, CodingKey { case type, status, vipType, vipStatus }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    let v = try? c.nestedContainer(keyedBy: VIP.self, forKey: .vip)
    func value(_ keys: VIP...) -> Int {
      for key in keys {
        if let n = try? v?.decode(Int.self, forKey: key) { return n }
        if let raw = try? v?.decode(String.self, forKey: key), let n = Int(raw) { return n }
      }
      return 0
    }
    let p = try? c.nestedContainer(keyedBy: Pendant.self, forKey: .pendant)
    self.init(
      name: try? c.decode(String.self, forKey: .uname),
      avatar: try? c.decode(String.self, forKey: .avatar),
      badge: try? c.decode(Badge.self, forKey: .official_verify),
      pendant: try? p?.decode(String.self, forKey: .image), vipStatus: value(.status, .vipStatus),
      vipType: value(.type, .vipType), card: nil)
  }
}
