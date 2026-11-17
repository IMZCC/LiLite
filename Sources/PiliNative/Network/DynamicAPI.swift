import Foundation

struct TopicLink: Decodable, Identifiable {
  let id: Int64, name: String
  var description: String? = nil
  var view: Int64? = nil, discuss: Int64? = nil
}
struct DynamicEntry: Identifiable {
  let id: String, author: String, body: String, date: String
  let signature: ReplyAuthor, originalAuthor: ReplyAuthor?
  let originalAuthorID: Int64?, tag: String?, authorBadge: String?, authorNavigable: Bool
  let forwardCount: Int64?, likeCount: Int64?, commentCount: Int64?
  let shareResource: String?, authorFace: URL?, blockedAttachment: Bool
  let bodyNodes: [RichNode], originalNodes: [RichNode]
  let resources: MomentResources, originalResources: MomentResources?
  let interactionLines: [(type: Int, nodes: [RichNode])]
  let presentation: DynamicModules
  let hasOpus: Bool
  let visible: Bool, foldIDs: [String], foldTitle: String, filterTexts: [String], hasGoods: Bool
  let voteID: Int64?, laterBVID: String?
  let authorID: Int64?, replyOID: Int64?, replyType: Int?
  let media: [GalleryPicture]
  var pictures: [URL] { media.map(\.url) }
  let video: Video?, topic: TopicLink?, originalID: String?, summary: String?,
    liked: Bool, pinned: Bool
  init?(_ dict: [String: Any]) {
    typealias Map = [String: Any]
    func int(_ value: Any?) -> Int64? {
      if let n = value as? NSNumber { return n.int64Value }
      return (value as? String).flatMap(Int64.init)
    }
    guard let id = dict["id_str"] as? String, let m = dict["modules"] as? Map else { return nil }
    self.id = id
    let a = m["module_author"] as? Map ?? [:]
    let d = m["module_dynamic"] as? Map ?? [:]
    author = a["name"] as? String ?? ""
    authorID = int(a["mid"])
    signature = ReplyAuthor(dynamic: a)
    authorBadge = (a["icon_badge"] as? Map)?["text"] as? String
    authorNavigable = (a["type"] as? String).map { $0 == "AUTHOR_TYPE_NORMAL" } ?? true
    tag = (m["module_tag"] as? Map)?["text"] as? String
    let stat = m["module_stat"] as? Map
    commentCount = int((stat?["comment"] as? Map)?["count"])
    forwardCount = int((stat?["forward"] as? Map)?["count"])
    likeCount = int((stat?["like"] as? Map)?["count"])
    date = [a["pub_time"] as? String, a["pub_action"] as? String, authorBadge].compactMap { $0 }
      .filter { !$0.isEmpty }.joined(separator: " · ")
    voteID = int(((d["additional"] as? Map)?["vote"] as? Map)?["vote_id"])
    let major = d["major"] as? Map ?? [:]
    resources = MomentResources(d)
    interactionLines = (((m["module_interaction"] as? Map)?["items"]) as? [Map] ?? []).compactMap {
      item in
      guard let d = item["desc"] as? Map else { return nil }
      var nodes = RichNode.body(d,dynamicID:id)
      if nodes.isEmpty, let text = d["text"] as? String, !text.isEmpty {
        nodes = [RichNode(text: text)]
      }
      return nodes.isEmpty ? nil : (Int(exactly: int(item["type"]) ?? 0) ?? 0, nodes)
    }
    presentation = DynamicModules(m, major: major)
    shareResource = ((dict["basic"] as? Map)?["rid_str"] as? String)
    authorFace = (a["face"] as? String).flatMap(httpsURL)
    blockedAttachment = MomentResources.restricted(major)
    let opus = major["opus"] as? Map ?? [:]
    let fold = m["module_fold"] as? Map ?? [:]
    visible = dict["visible"] as? Bool ?? true
    foldIDs = (fold["ids"] as? [Any] ?? []).compactMap {
      ($0 as? String) ?? ($0 as? NSNumber)?.stringValue
    }
    foldTitle = fold["statement"] as? String ?? "展开折叠的动态"
    let filterFields=MomentFilterFields(current:d,original:((dict["orig"] as? Map)?["modules"] as? Map)?["module_dynamic"] as? Map)
    filterTexts=filterFields.texts;hasGoods=filterFields.goods
    hasOpus = !opus.isEmpty
    let description = d["desc"] as? Map
    let opusSummary = opus["summary"] as? Map
    let primary = RichNode.body(description,dynamicID:id)
    bodyNodes = primary.isEmpty ? RichNode.body(opusSummary,dynamicID:id) : primary
    body =
      (d["desc"] as? Map)?["text"] as? String ?? (opus["summary"] as? Map)?["text"] as? String
      ?? opus["title"] as? String ?? ""
    if let arc = major["archive"] as? Map, let bv = arc["bvid"] as? String {
      video = Video.preview(
        id: bv, title: arc["title"] as? String ?? bv, cover: arc["cover"] as? String ?? "",
        author: a["name"] as? String)
    } else {
      video = nil
    }
    let draw = major["draw"] as? Map
    media = (opus["pics"] as? [Map] ?? draw?["items"] as? [Map] ?? []).compactMap(
      GalleryPicture.init)
    let basic = dict["basic"] as? Map
    replyOID = int(basic?["comment_id_str"]).flatMap { $0 > 0 ? $0 : nil }
    replyType = int(basic?["comment_type"]).flatMap(Int.init(exactly:)).flatMap {
      $0 > 0 ? $0 : nil
    }
    liked = MomentResources.likeStatus(dict) ?? false
    pinned = ((m["module_tag"] as? Map)?["text"] as? String)?.contains("置顶") == true
    if let t = d["topic"] as? Map, let tid = int(t["id"]), let name = t["name"] as? String {
      topic = TopicLink(id: tid, name: name)
    } else {
      topic = nil
    }
    let orig = dict["orig"] as? Map
    originalID = orig?["id_str"] as? String
    let originalModule = (orig?["modules"] as? Map)?["module_dynamic"] as? Map
    let originalVisible = (orig?["visible"] as? Bool) != false
    let originalAvailable =
      originalVisible && !MomentResources.restricted(originalModule?["major"] as? Map ?? [:])
    let srcAuthor = originalAvailable ? (orig?["modules"] as? Map)?["module_author"] as? Map : nil
    originalAuthor = srcAuthor.map(ReplyAuthor.init(dynamic:))
    originalAuthorID = int(srcAuthor?["mid"])
    let origDyn = originalAvailable ? originalModule : nil
    originalResources =
      originalVisible
      ? originalModule.map { MomentResources($0, quotedID: orig?["id_str"] as? String) } : nil
    func watched(_ m: Map?) -> String? {
      guard let m, !MomentResources.restricted(m) else { return nil }
      return
        ([m["archive"], m["ugc_season"]].compactMap { $0 as? Map }.compactMap {
          $0["bvid"] as? String
        }).first { SharedLink.parse($0) != nil }
    }
    laterBVID = watched(major) ?? watched(origDyn?["major"] as? Map)
    let origDescription = origDyn?["desc"] as? Map
    let indexed = RichNode.body(origDescription,dynamicID:originalID)
    let origMajor = origDyn?["major"] as? Map
    originalNodes =
      indexed.isEmpty ? RichNode.body((origMajor?["opus"] as? Map)?["summary"] as? Map,dynamicID:originalID) : indexed
    summary =
      (origDyn?["desc"] as? Map)?["text"] as? String
      ?? (((origDyn?["major"] as? Map)?["archive"] as? Map)?["title"] as? String)
  }
}
extension BiliAPI {
  func dynamicData(_ path: String, _ q: [String: String], expectedAccount: String? = nil)
    async throws -> [String: Any]
  {
    let bytes = try await fetch(path, q, host: "api.bilibili.com", expectedAccount: expectedAccount)
    guard let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      root["code"] as? Int == 0, let data = root["data"] as? [String: Any]
    else {
      struct Failed: Decodable { let code:Int?; let message:String? }
      let failure=try? JSONDecoder().decode(Failed.self, from:bytes)
      throw ServiceError.readFailure(path,fields:q,code:failure?.code,message:failure?.message ?? "无法加载内容")
    }
    return data
  }
  func dynamics(
    offset: String?, author: Int64? = nil,
    videoOnly: Bool = false, keyword: String = "", feedType: String? = nil,
    followedCreator: Int64? = nil, user: String? = nil
  ) async throws -> Page<DynamicEntry> {
    var fields = [
      "offset": offset ?? "", "type": feedType ?? (videoOnly ? "video" : "all"),
      "features": "itemOpusStyle",
      "timezone_offset": "-480",
    ]
    var path = "/x/polymer/web-dynamic/v1/feed/all"
    if let author {
      path = "/x/polymer/web-dynamic/v1/feed/space"
      fields["host_mid"] = "\(author)"
      if !keyword.isEmpty { fields["q"] = keyword }
    }
    if let followedCreator {
      fields["type"] = nil
      fields["host_mid"] = String(followedCreator)
    }
    let data = try await dynamicData(path, fields, expectedAccount: user)
    if offset == nil, let uid = user, feedType == "all", author == nil,
      followedCreator == nil, let baseline = data["update_baseline"] as? String, !baseline.isEmpty
    {
      UserDefaults.standard.set(baseline, forKey: "social.feed.baseline." + uid)
    }
    let rows = data["items"] as? [[String: Any]] ?? []
    let filter=try MomentListFilter.current()
    let items=rows.compactMap{DynamicEntry($0["dynamic_card_item"] as? [String:Any] ?? $0)}.filter(filter.accepts)
    let next = data["offset"] as? String
    return Page(
      items: items, next: data["has_more"] as? Bool == true && next != offset ? next : nil)
  }
  func dynamic(_ id: String, byAlbum: Bool = false, expectedAccount: String? = nil) async throws
    -> DynamicEntry
  {
    let p = try await dynamicData(
      "/x/polymer/web-dynamic/v1/detail",
      [
        "features": "itemOpusStyle", "timezone_offset": "-480",
        "web_location": "333.1330",
      ].merging(byAlbum ? ["rid": id, "type": "2"] : ["id": id]) { $1 },
      expectedAccount: expectedAccount)
    guard let row = p["item"] as? [String: Any], let entry = DynamicEntry(row) else {
      throw ServiceError("该动态暂不可用")
    }
    return entry
  }
  func dynPost(
    _ path: String, _ body: [String: Any], expectedAccount: String? = nil,
    signedQuery: [String: String]? = nil
  ) async throws
    -> [String: Any]
  {
    guard let user = try await AccountJar.shared.current(), let csrf = user.csrf else {
      throw ServiceError("请先登录")
    }
    if let expectedAccount, user.id != expectedAccount { throw ServiceError("账号已切换") }
    var c = URLComponents()
    c.scheme = "https"
    c.host = "api.bilibili.com"
    c.path = path
    if let signedQuery {
      guard signedQuery["csrf"] == csrf else { throw ServiceError("账号凭据已更新，请重试") }
      c.queryItems = signedQuery.sorted { $0.key < $1.key }.map(URLQueryItem.init)
    } else {
      c.queryItems = [.init(name: "csrf", value: csrf), .init(name: "platform", value: "web")]
    }
    guard let url = c.url else { throw URLError(.badURL) }
    var r = URLRequest(url: url, timeoutInterval: 20)
    r.httpMethod = "POST"
    r.httpShouldHandleCookies = false
    r.setValue(user.header, forHTTPHeaderField: "Cookie")
    r.setValue("https://t.bilibili.com/", forHTTPHeaderField: "Referer")
    r.setValue("application/json", forHTTPHeaderField: "Content-Type")
    r.httpBody = try JSONSerialization.data(withJSONObject: body)
    let (d, h) = try await webResponse(r, identity: user)
    guard let result = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
      throw URLError(.cannotParseResponse)
    }
    guard (h as? HTTPURLResponse)?.statusCode == 200, result["code"] as? Int == 0 else {
      throw ServiceError(result["message"] as? String ?? "操作失败")
    }
    return result["data"] as? [String: Any] ?? [:]
  }
}

extension MomentListFilter{func accepts(_ item:DynamicEntry)->Bool{accepts(texts:item.filterTexts,goods:item.hasGoods)}}
