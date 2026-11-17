import Foundation

extension BiliAPI {
  func searchSuggestions(_ term: String, owner: String? = nil) async throws -> [String] {
    let r = try await read(
      "/x/web-interface/suggest",
      try await sign([
        "term": term, "highlight": "0", "spmid": "333.1365", "web_location": "333.1365",
      ]), expectedAccount: owner, as: SearchSuggestionsPayload.self)
    var seen = Set<String>()
    return (r.result?.tag ?? []).compactMap(\.term).filter {
      !$0.isEmpty && seen.insert($0).inserted
    }
  }
  func searchPicks(owner: String? = nil) async throws -> [Trend] {
    struct Payload: Decodable { let list: [Trend]? }
    return try await read(
      "/x/v2/search/recommend",
      [
        "build": "8430300", "channel": "appstore", "version": "8.43.0", "c_locale": "zh_CN",
        "mobi_app": "iphone", "platform": "ios", "s_locale": "zh_CN", "from": "2",
      ], host: "app.bilibili.com", expectedAccount: owner, as: Payload.self
    ).list ?? []
  }
  func searchPage(
    _ keyword: String, domain: SearchDomain, page: Int, fields: [String: String], owner: String?
  ) async throws -> Page<SearchHit> {
    let mixed = domain == .mixed && page == 1
    let type = domain == .mixed ? SearchDomain.video.service : domain.service
    var q = [
      "keyword": keyword, "page": String(page), "page_size": "20", "platform": "pc",
      "web_location": "1430654",
    ]
    if !mixed { q["search_type"] = type }
    for (k, v) in fields
    where [
      "order", "duration", "tids", "pubtime_begin_s", "pubtime_end_s", "order_sort", "user_type",
      "category_id",
    ].contains(k) { q[k] = v }
    let data = try await dynamicData(
      mixed ? "/x/web-interface/wbi/search/all/v2" : "/x/web-interface/wbi/search/type",
      try await sign(q), expectedAccount: owner)
    if let voucher = data["v_voucher"] as? String, !voucher.isEmpty {
      throw ServiceError.searchCheck(keyword)
    }
    let blocked = RecommendationRules.current().blockedCreators
    let total = SearchHit.num(data["numResults"]).map(Int.init)
    let raw = data["result"] as? [[String: Any]] ?? []
    var size = raw.count
    let rows: [SearchHit]
    if mixed {
      size =
        raw.first { ($0["result_type"] as? String) == "video" }.flatMap {
          $0["data"] as? [[String: Any]]
        }?.count ?? 0
      rows = raw.flatMap { g -> [SearchHit] in
        let type = g["result_type"] as? String ?? ""
        return (g["data"] as? [[String: Any]] ?? []).flatMap {
          SearchHit.decode(type, $0, blocked: blocked)
        }
      }
    } else {
      rows = raw.flatMap { SearchHit.decode(type, $0, blocked: blocked) }
    }
    let more =
      SearchHit.num(data["numPages"]).map { Int64(page) < $0 } ?? total.map { page * 20 < $0 }
      ?? (size >= 20)
    return Page(
      items: rows, next: more && (mixed || size > 0) ? String(page + 1) : nil, reportedTotal: total)
  }
}
