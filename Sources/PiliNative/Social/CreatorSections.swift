import Foundation

enum CreatorSection: Int, CaseIterable, Identifiable {
  case automatic, home, dynamic, contribute, favorite, bangumi, cheese, shop
  static let preference = "creator.initialSection"
  var id: Int { rawValue }
  var param: String {
    ["def", "home", "dynamic", "contribute", "favorite", "bangumi", "cheese", "shop"][rawValue]
  }
  var label: String { ["默认", "主页", "动态", "投稿", "收藏", "番剧", "课堂", "小店"][rawValue] }
  init?(param: String?) {
    guard let v = Self.allCases.first(where: { $0.param == param }) else { return nil }
    self = v
  }
}

private struct SpaceKey: CodingKey {
  let stringValue: String
  var intValue: Int? { nil }
  init(_ key: String) { stringValue = key }
  init?(stringValue: String) { self.init(stringValue) }
  init?(intValue: Int) { return nil }
}
extension KeyedDecodingContainer where K == SpaceKey {
  fileprivate func string(_ key: String) -> String? {
    if let v = try? decode(String.self, forKey: .init(key)), !v.isEmpty { return v }
    return nil
  }
  fileprivate func number(_ key: String) -> Int64? {
    (try? decode(Int64.self, forKey: .init(key))) ?? string(key).flatMap(Int64.init)
  }
  fileprivate func child(_ key: String) -> Self? {
    try? nestedContainer(keyedBy: SpaceKey.self, forKey: .init(key))
  }
  fileprivate func items<T: Decodable>(_ key: String, _: T.Type) -> [T] {
    (try? decode([SpaceElement<T>].self, forKey: .init(key)))?.compactMap(\.value) ?? []
  }
}
private struct SpaceElement<T: Decodable>: Decodable {
  let value: T?
  init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

enum CreatorHomeKind: String, CaseIterable, Identifiable {
  case archive
  case favorite = "favourite2"
  case coins = "coin_archive"
  case likes = "like_archive"
  case article, audios, comic, season
  var id: Self { self }
  var label: String {
    switch self {
    case .archive: return "视频"
    case .favorite: return "收藏"
    case .coins: return "最近投币的视频"
    case .likes: return "最近点赞的视频"
    case .article: return "图文"
    case .audios: return "音频"
    case .comic: return "漫画"
    case .season: return "追番"
    }
  }
  var visibilityKey: String? {
    switch self {
    case .favorite: return "fav_video"
    case .coins: return "coins_video"
    case .likes: return "likes_video"
    case .season: return "bangumi"
    default: return nil
    }
  }
}
struct CreatorSpaceRecord: Decodable {
  struct Tab: Decodable, Identifiable {
    let param: String, title: String?, season: Int64?, series: Int64?, items: [Self]
    var id: String { param + ":\(season ?? 0):\(series ?? 0)" }
    init(from d: Decoder) throws {
      let c = try d.container(keyedBy: SpaceKey.self)
      param = c.string("param") ?? ""
      title = c.string("title")
      season = c.number("season_id")
      series = c.number("series_id")
      items = c.items("items", Self.self)
    }
    init(_ param: String, _ title: String) {
      self.param = param
      self.title = title
      season = nil
      series = nil
      items = []
    }
  }
  enum Destination: Hashable {
    case link(SharedLink)
    case folder(Int64)
    case comic(Int64)
  }
  struct Media: Identifiable {
    let destination: Destination, title: String, cover: String?, note: String?
    var plays: Int64? = nil, danmaku: Int64? = nil, seconds: Int64? = nil
    var id: Destination { destination }
  }
  struct Item: Decodable {
    let title: String?, cover: String?, uri: String?, bvid: String?, param: Int64?, id: Int64?,
      mediaID: Int64?, kind: String?, note: String?, pgc: Bool
    let plays: Int64?, danmaku: Int64?, seconds: Int64?
    init(from d: Decoder) throws {
      let c = try d.container(keyedBy: SpaceKey.self)
      plays = c.number("play")
      danmaku = c.number("danmaku")
      seconds = c.number("duration")
      title = c.string("title")
      cover = c.string("cover") ?? c.items("origin_image_urls", String.self).first
      uri = c.string("uri")
      bvid = c.string("bvid")
      param = c.number("param")
      id = c.number("id")
      mediaID = c.number("media_id")
      kind = c.string("goto")
      note = c.string("publish_time_text") ?? c.string("label") ?? c.string("length")
      pgc = (try? c.decode(Bool.self, forKey: .init("is_pgc"))) ?? false
    }
    func row(_ type: CreatorHomeKind) -> Media? {
      func pos(_ n: Int64?) -> Int64? { n.flatMap { $0 > 0 ? $0 : nil } }
      let uriRoute = uri.flatMap(SharedLink.parse)
      let key = pos(param)
      let dest: Destination?
      switch type {
      case .archive, .coins, .likes:
        if kind == "bangumi", let key {
          dest = .link(.episode(key))
        } else if pgc {
          dest = uriRoute.map(Destination.link)
        } else {
          dest = (uriRoute ?? bvid.flatMap(SharedLink.parse) ?? key.map { .archive($0, 1) }).map(
            Destination.link)
        }
      case .favorite: dest = (pos(mediaID) ?? pos(id)).map(Destination.folder)
      case .article:
        let u = uri.flatMap(URL.init(string:))
        let article: Int64? =
          ["article", "read"].contains(u?.host ?? "")
          ? pos(u.flatMap { Int64($0.lastPathComponent) }) : nil
        dest = (uriRoute ?? article.map(SharedLink.article)).map(Destination.link)
      case .audios: dest = pos(id).map { .link(.song($0)) }
      case .comic: dest = key.map(Destination.comic)
      case .season: dest = key.map { .link(.season($0)) } ?? uriRoute.map(Destination.link)
      }
      guard let dest else { return nil }
      return Media(
        destination: dest, title: title ?? type.label, cover: cover, note: note, plays: plays,
        danmaku: danmaku, seconds: seconds)
    }
  }
  struct Group: Identifiable {
    let kind: CreatorHomeKind, count: Int, items: [Media], visible: Bool?
    var id: CreatorHomeKind { kind }
  }
  struct Reservation: Decodable, Identifiable {
    let id: Int64, name: String, date: Int64?, summary: String?, dynamic: String?, prize: String?,
      prizeURL: String?
    var count: Int64, followed: Bool
    init(from d: Decoder) throws {
      let c = try d.container(keyedBy: SpaceKey.self)
      id = c.number("sid") ?? 0
      name = c.string("name") ?? "预约"
      count = max(0, c.number("total") ?? 0)
      followed = c.number("is_follow") == 1
      date = c.number("live_plan_start_time")
      summary = c.child("desc_text_1")?.string("text")
      dynamic = c.string("dynamic_id") ?? c.number("dynamic_id").map(String.init)
      prize = c.child("lottery_prize_info")?.string("text")
      prizeURL = c.child("lottery_prize_info")?.string("jump_url")
    }
  }
  struct HeaderDetails: Decodable {
    struct Banner: Decodable {
      let full: String, preview: String, title: String?, subtitle: String?, alignment: Double
      init(from d: Decoder) throws {
        let row = try d.container(keyedBy: SpaceKey.self)
        guard let full = row.string("cover") else { throw DecodingError.keyNotFound(SpaceKey("cover"), .init(codingPath: d.codingPath, debugDescription: "No cover")) }
        self.full = full
        let item = row.child("item"), img = item?.child("image"), visual = img ?? item?.child("animation")
        preview = img?.string("default_image") ?? full
        title = row.child("title")?.string("title")
        subtitle = row.child("title")?.string("sub_title")
        if let raw = visual?.string("location"), let h = visual?.number("height"), h > 0 {
          let parts = raw.split(separator: "-").dropFirst().prefix(2).compactMap { Double($0) }
          alignment = parts.count == 2 ? min(1, max(-1, (parts[0] + parts[1]) / Double(h) - 1)) : 0
        } else { alignment = 0 }
      }
    }
    struct Tag: Decodable { let title: String?, uri: String? }
    struct FanFace: Decodable { let face: String?, avatar: String? }
    let day: String?, night: String?, banners: [Banner], tags: [Tag], promo: String?, promoURL: String?
    let muted: Bool, medal: String?, medalLevel: Int?, chargeCount: Int?, guardCount: Int?, charges: [String], guards: [String]
    init(from d: Decoder) throws {
      let c = try d.container(keyedBy: SpaceKey.self)
      let card = c.child("card"), images = c.child("images"), ad = card?.child("pr_info")
      day = images?.string("imgUrl"); night = images?.string("night_imgurl")
      banners = images?.child("collection_top_simple")?.child("top")?.items("result",Banner.self) ?? []
      tags = (card?.items("space_tag",Tag.self) ?? []).filter { !($0.title ?? "").isEmpty }
      promo = ad?.string("content"); promoURL = ad?.string("url"); muted = card?.number("silence") == 1
      let mark = card?.child("live_fans_wearing")?.child("detail_v2")
      medal = mark?.string("medal_name"); medalLevel = mark?.number("level").flatMap(Int.init(exactly:))
      let charge = c.child("elec"), fleet = c.child("guard")
      charges = charge?.items("list",FanFace.self).compactMap { $0.avatar ?? $0.face } ?? []
      guards = fleet?.items("item",FanFace.self).compactMap { $0.face ?? $0.avatar } ?? []
      chargeCount = charge?.number("total").flatMap(Int.init(exactly:))
      guardCount = fleet?.string("desc").flatMap { Int($0.prefix { ch in ch.isASCII && ch.isNumber }) }
    }
  }
  let headerDetails: HeaderDetails
  let reservations: [Reservation]
  struct Person: Decodable {
    let followsViewer: Bool
    let name: String?, sign: String?, face: String?, pendant: String?, verifyType: Int?,
      verifyText: String?, vipStatus: Int, vipType: Int
    let following: Int64?, fans: Int64?, likes: Int64?, level: Int64?, birthday: String?,
      registered: Int64?
    init(from d: Decoder) throws {
      let c = try d.container(keyedBy: SpaceKey.self)
      name = c.string("name")
      followsViewer = c.child("relation")?.number("is_followed") == 1
      sign = c.string("sign")
      face = c.string("face")
      pendant = c.child("pendant")?.string("image")
      verifyType = c.child("official_verify")?.number("type").flatMap(Int.init(exactly:))
      verifyText = c.child("official_verify")?.string("desc")
      let v = c.child("vip")
      vipStatus = Int(exactly: v?.number("status") ?? v?.number("vipStatus") ?? 0) ?? 0
      vipType = Int(exactly: v?.number("type") ?? v?.number("vipType") ?? 0) ?? 0
      following = c.number("attention") ?? c.number("friend")
      fans = c.number("fans")
      likes = c.child("likes")?.number("like_num")
      level = c.child("level_info")?.number("current_level")
      birthday = c.string("birthday")
      registered = c.number("regtime")
    }
  }
  let tabs: [Tab], recommended: String?, groups: [Group], hasSeries: Bool, person: Person?
  let room: Int64?, onAir: Bool, roomTitle: String?, medalsVisible: Bool, ownsMedal: Bool
  let hasHome: Bool
  init(from d: Decoder) throws {
    let c = try d.container(keyedBy: SpaceKey.self)
    headerDetails = try HeaderDetails(from: d)
    let settings = c.child("setting")
    let live = c.child("live")
    tabs = c.items("tab2", Tab.self)
    recommended = c.string("default_tab")
    person = try? c.decode(Person.self, forKey: .init("card"))
    var rawHome = false
    groups = CreatorHomeKind.allCases.compactMap { kind in
      guard let group = c.child(kind.rawValue) else { return nil }
      let raw = group.items("item", Item.self)
      guard !raw.isEmpty else { return nil }
      rawHome = true
      var seen = Set<Destination>()
      let items = raw.compactMap { $0.row(kind) }.filter { seen.insert($0.id).inserted }
      let visible = kind.visibilityKey.flatMap { settings?.number($0) }.map { $0 == 1 }
      return Group(
        kind: kind, count: (group.number("count").flatMap(Int.init(exactly:))) ?? raw.count,
        items: items, visible: visible)
    }
    var seenReservations = Set<Int64>()
    reservations = c.items("reservation_card_list", Reservation.self).filter {
      $0.id > 0 && seenReservations.insert($0.id).inserted
    }
    hasHome = rawHome
    hasSeries =
      (c.child("ugc_season")?.number("count") ?? 0) > 0
      || !(c.child("series")?.items("item", Item.self) ?? []).isEmpty
    room =
      (live?.number("roomStatus") == 1) ? live?.number("roomid").flatMap { $0 > 0 ? $0 : nil } : nil
    onAir = live?.number("liveStatus") == 1
    roomTitle = live?.string("title")
    ownsMedal = c.number("medal") == 1
    medalsVisible =
      settings?.number("close_space_medal") != 1
      && ((c.number("medal") ?? 0) > 0
        || c.child("card")?.child("live_fans_wearing")?.child("detail_v2") != nil)
  }
  func sections(shop: Bool) -> [Tab] {
    var seen = Set<String>()
    return tabs.filter {
      guard let kind = CreatorSection(param: $0.param), kind != .automatic,
        kind != .shop || shop, kind != .home || hasHome
      else { return false }
      return seen.insert($0.param).inserted
    }
  }
  func preferred(_ choice: Int, in available: [Tab]) -> String? {
    [
      CreatorSection(rawValue: choice)?.param, recommended == "video" ? "contribute" : recommended,
      available.first?.param,
    ]
    .compactMap { $0 }.first { requested in available.contains { $0.param == requested } }
  }
  func contributions(_ tab: Tab) -> [Tab] {
    var seen = Set<String>()
    var list = tab.items.filter {
      [
        "video", "charging_video", "article", "opus", "audio", "comic", "season_video", "series",
        "ugcSeason",
      ].contains($0.param)
        && ($0.param != "season_video" || ($0.season ?? 0) > 0)
        && ($0.param != "series" || ($0.series ?? 0) > 0)
        && seen.insert($0.id).inserted
    }
    if list.count > 1 && hasSeries && !list.contains(where: { $0.param == "ugcSeason" }) {
      list.append(.init("ugcSeason", "全部合集/列表"))
    }
    return list
  }
}
