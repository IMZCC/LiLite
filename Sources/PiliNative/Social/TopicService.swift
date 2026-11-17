import Foundation

struct TopicHeader: Decodable {
  struct Host: Decodable { let uid: Int64?, name: String?, face: String? }
  struct Item: Decodable {
    let id: Int64, name: String
    let description: String?, view: Int64?, discuss: Int64?
    var like: Int64?, fav: Int64?, is_like: Bool?, is_fav: Bool?
  }
  var topic_item: Item?
  let topic_creator: Host?
  var authenticatedOwner: String? = nil
  private enum CodingKeys: String, CodingKey { case topic_item, topic_creator }
}

enum TopicToggle {
  case like, favorite
  var name: String { self == .like ? "点赞" : "收藏" }
  func state(_ item: TopicHeader.Item) -> Bool? { self == .like ? item.is_like : item.is_fav }
  func apply(_ on: Bool, to item: inout TopicHeader.Item) {
    switch self {
    case .like:
      if let n = item.like, item.is_like != on { item.like = max(0, n + (on ? 1 : -1)) }
      item.is_like = on
    case .favorite:
      if let n = item.fav, item.is_fav != on { item.fav = max(0, n + (on ? 1 : -1)) }
      item.is_fav = on
    }
  }
}

struct TopicSort: Identifiable { let id: Int, name: String }
enum TopicCard: Identifiable {
  case dynamic(DynamicEntry), fold(String, String), unknown(String, String)
  var id: String {
    switch self {
    case .dynamic(let entry): return "d:" + entry.id
    case .fold(let key, _), .unknown(let key, _): return key
    }
  }
}
struct TopicPage {
  let cards: [TopicCard], sorts: [TopicSort]?, shown: Int?, next: String?
  init(_ payload: [String:Any], cursor: String?) {
    let data = payload["topic_card_list"] as? [String:Any] ?? [:]
    let options = data["topic_sort_by_conf"] as? [String:Any]
    shown = options?["show_sort_by"] as? Int
    sorts = (options?["all_sort_by"] as? [[String:Any]])?.compactMap {
      guard let n = $0["sort_by"] as? Int, let name = $0["sort_name"] as? String, !name.isEmpty else { return nil }
      return TopicSort(id: n, name: name)
    }
    let offset = data["offset"] as? String
    next = data["has_more"] as? Bool == true && offset != cursor && offset != "" ? offset : nil
    cards = (data["items"] as? [[String:Any]] ?? []).enumerated().compactMap { index, card in
      if let raw = card["dynamic_card_item"] as? [String:Any], let entry = DynamicEntry(raw) {
        return .dynamic(entry)
      }
      let key = (cursor ?? "") + ":" + String(index)
      if let fold = card["fold_card_item"] as? [String:Any] {
        let count = fold["fold_count"] as? Int ?? 0
        let fallback = count > 0 ? "展开 \(count) 条折叠动态" : "展开折叠动态"
        let text = fold["fold_desc"] as? String
        return .fold("f:" + key, text?.isEmpty == false ? text! : fallback)
      }
      if let kind = card["topic_type"] as? String, !kind.isEmpty { return .unknown("u:" + key, kind) }
      return nil
    }
  }
  static func unique(_ cards: [TopicCard]) -> [TopicCard] {
    var seen = Set<String>()
    return cards.filter { seen.insert($0.id).inserted }
  }
  func expand(_ placeholder: String, in existing: [TopicCard]) -> [TopicCard] {
    guard let index = existing.firstIndex(where: { $0.id == placeholder }) else { return existing }
    // The fold endpoint has no cursor. Never generate a new copy of the same fold affordance.
    let entries = cards.filter { if case .fold = $0 { return false }; return true }
    var result = existing
    result.replaceSubrange(index...index, with: entries)
    return Self.unique(result)
  }
}

extension BiliAPI {
  private struct TopResponse: Decodable { let top_details: TopicHeader? }
  func topicIndex(search: Bool, fields: [String: String], owner: String, page: Int) async throws -> Page<TopicLink> {
    struct Index: Decodable {
      struct Info: Decodable { let has_more: Bool? }
      let topic_items: [TopicLink]?, page_info: Info?
    }
    struct Reply: Decodable { let code: Int, message: String?, data: Index? }
    let bytes = try await fetch(search ? "/x/topic/pub/search" : "/x/topic/web/dynamic/rcmd", fields,
      host: search ? "app.bilibili.com" : "api.bilibili.com", expectedAccount: owner)
    let reply = try JSONDecoder().decode(Reply.self, from: bytes)
    guard reply.code == 0 else { throw ServiceError(reply.message ?? "无法加载话题") }
    let rows = reply.data?.topic_items ?? []
    return Page(items: rows, next: search && !rows.isEmpty && reply.data?.page_info?.has_more == true ? String(page + 1) : nil)
  }
  func topicHeader(_ id: Int64, recommend: String) async throws -> TopicHeader {
    struct Envelope: Decodable { let code: Int, message: String?, data: TopResponse? }
    let result = try await mobileREST("/x/topic/web/details/top", ["topic_id": String(id), "source": "Web"],
      use: .role(.recommend), expectedAccount: recommend)
    let reply = try JSONDecoder().decode(Envelope.self, from: result.data)
    guard reply.code == 0, var value = reply.data?.top_details, value.topic_item?.id == id else {
      throw ServiceError(reply.message ?? "话题资料暂不可用")
    }
    value.authenticatedOwner = result.session.token?.isEmpty == false ? result.session.owner : nil
    return value
  }
  // Only on explicit user action when the recommended-feed identity is not the writer.
  func ownTopicState(_ id: Int64, main: String) async throws -> TopicHeader.Item {
    guard id > 0, !main.isEmpty else { throw ServiceError("账号已切换") }
    struct Envelope: Decodable { let code: Int, message: String?, data: TopResponse? }
    let result = try await mobileREST("/x/topic/web/details/top", ["topic_id": String(id), "source": "Web"],
      use: .role(.main), expectedAccount: main, requiresToken: true)
    let response = try JSONDecoder().decode(Envelope.self, from: result.data)
    guard response.code == 0, let item = response.data?.top_details?.topic_item, item.id == id else {
      throw ServiceError(response.message ?? "无法读取主账号状态")
    }
    return item
  }
  func topicPage(_ id: Int64, cursor: String?, sort: Int, fold: Bool, owner: String) async throws -> TopicPage {
    var fields = ["topic_id": String(id), "sort_by": String(sort)]
    let route: String
    if fold { route = "/x/topic/web/details/fold" }
    else {
      route = "/x/polymer/web-dynamic/v1/feed/topic"
      fields["offset"] = cursor
      fields["page_size"] = "20"; fields["source"] = "Web"
      fields["features"] = "itemOpusStyle,listOnlyfans,opusBigCover,onlyfansVote,decorationCard,onlyfansAssetsV2,forwardListHidden,ugcDelete,onlyfansQaCard,commentsNewVersion,avatarAutoTheme,sunflowerStyle,cardsEnhance,eva3CardOpus,eva3CardVideo,eva3CardComment,eva3CardVote,eva3CardUser"
    }
    return TopicPage(try await dynamicData(route, fields, expectedAccount: owner), cursor: cursor)
  }
  func setTopic(_ id: Int64, _ type: TopicToggle, on: Bool, main: String) async throws {
    switch type {
    case .favorite:
      try await submit(on ? "/x/topic/fav/sub/add" : "/x/topic/fav/sub/cancel",
        ["topic_id": String(id)], expectedAccount: main)
    case .like:
      try await submit("/x/topic/like", ["action": on ? "like" : "cancel_like", "up_mid": main,
        "business": "topic", "topic_id": String(id)], expectedAccount: main)
    }
  }
}

struct TopicAddress {
  static func share(_ id: Int64) -> URL {
    URL(string: "https://m.bilibili.com/topic-detail?topic_id=\(id)")!
  }
  static func report(_ id: Int64, name: String, dark: Bool) -> URL? {
    var url = URLComponents()
    url.scheme = "https"; url.host = "www.bilibili.com"; url.path = "/h5/topic-active/topic-report"
    url.queryItems = [.init(name: "topic_id", value: String(id)), .init(name: "topic_name", value: name),
      .init(name: "native.theme", value: dark ? "2" : "1"), .init(name: "night", value: dark ? "1" : "0")]
    return url.url
  }
}
