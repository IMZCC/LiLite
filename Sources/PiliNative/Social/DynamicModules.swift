import Foundation

enum FeedScope: Int, CaseIterable, Identifiable {
  case all, video, pgc, article
  static let setting = "social.defaultFeed"
  var id: Self { self }
  var request: String {
    switch self {
    case .all: "all"
    case .video: "video"
    case .pgc: "pgc"
    case .article: "article"
    }
  }
  var label: String {
    switch self {
    case .all: "全部"
    case .video: "投稿"
    case .pgc: "番剧"
    case .article: "专栏"
    }
  }
}
struct DynamicModules {
  typealias Map = [String: Any]
  struct Notice { let title: String, body: String, link: URL? }
  struct Attachment { let title: String, cover: URL?, route: SharedLink }
  let notice: Notice?, interactions: [String], attachment: Attachment?
  init(_ modules: Map, major: Map) {
    func link(_ value: Any?) -> URL? {
      guard let text = value as? String, let u = httpsURL(text), let host = u.host?.lowercased(),
        host == "bilibili.com" || host.hasSuffix(".bilibili.com"), u.user == nil, u.password == nil
      else { return nil }
      return u
    }
    func number(_ value: Any?) -> Int64? {
      let id = (value as? NSNumber)?.int64Value ?? (value as? String).flatMap(Int64.init)
      return id.flatMap { $0 > 0 ? $0 : nil }
    }
    if let d = modules["module_dispute"] as? Map, let t = d["title"] as? String, !t.isEmpty {
      notice = Notice(title: t, body: d["desc"] as? String ?? "", link: link(d["jump_url"]))
    } else {
      notice = nil
    }
    interactions = ((modules["module_interaction"] as? Map)?["items"] as? [Map] ?? []).compactMap {
      row in
      guard let desc = row["desc"] as? Map else { return nil }
      let text =
        (desc["text"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        ?? (desc["rich_text_nodes"] as? [Map] ?? []).compactMap {
          $0["text"] as? String ?? $0["orig_text"] as? String
        }.joined()
      return text.isEmpty ? nil : text
    }
    var item: Attachment?
    for key in ["pgc", "courses", "ugc_season"] {
      guard let card = major[key] as? Map else { continue }
      let jump = (card["jump_url"] as? String).flatMap {
        SharedLink.parse($0) ?? link($0).flatMap { SharedLink.parse($0.absoluteString) }
      }
      let dest: SharedLink?
      switch key {
      case "pgc":
        dest =
          number(card["epid"]).map(SharedLink.episode) ?? jump
          ?? number(card["season_id"]).map(SharedLink.season)
      case "courses":
        dest = jump ?? number(card["season_id"] ?? card["id"]).map { .course($0, false) }
      default:
        dest =
          (card["bvid"] as? String).flatMap(SharedLink.parse) ?? jump
          ?? number(card["aid"]).map { .archive($0, nil) }
      }
      if let dest {
        item = Attachment(
          title: card["title"] as? String ?? "查看内容",
          cover: (card["cover"] as? String).flatMap(httpsURL), route: dest)
        break
      }
    }
    attachment = item
  }
}

/// Lists (including a creator's search) filter source and repost independently, like DynamicsDataModel.fromJson.
struct MomentFilterFields {
  let texts:[String],goods:Bool
  init(current:[String:Any],original:[String:Any]?){
    typealias M=[String:Any]
    func fields(_ module:M)->(String,Bool){
      let major=module["major"] as? M ?? [:],opus=major["opus"] as? M ?? [:]
      let names=["MAJOR_TYPE_ARCHIVE":"archive","MAJOR_TYPE_UGC_SEASON":"ugc_season","MAJOR_TYPE_PGC":"pgc","MAJOR_TYPE_COURSES":"courses"]
      let title=(major["type"] as? String).flatMap{names[$0]}.flatMap{(major[$0] as? M)?["title"] as? String}
      return ([opus["title"] as? String,(opus["summary"] as? M)?["text"] as? String,(module["desc"] as? M)?["text"] as? String,title].compactMap{$0}.joined(),(module["additional"] as? M)?["type"] as? String=="ADDITIONAL_TYPE_GOODS")
    }
    let first=fields(current),other=original.map(fields)
    texts=[first.0]+[other?.0].compactMap{$0};goods=first.1 || other?.1==true
  }
}
struct MomentListFilter {
  let hideGoods:Bool,regex:NSRegularExpression?
  init(goods:Bool,pattern:String)throws{hideGoods=goods;regex=pattern.isEmpty ? nil:try NSRegularExpression(pattern:pattern,options:.caseInsensitive)}
  static func current(_ d:UserDefaults = .standard)throws->Self{try .init(goods:d.bool(forKey:"social.hideGoods"),pattern:d.string(forKey:"social.dynamicRegex") ?? "")}
  func accepts(texts:[String],goods:Bool)->Bool{
    if hideGoods && goods{return false};guard let regex else{return true}
    return !texts.contains{value in regex.firstMatch(in:value,range:NSRange(value.startIndex...,in:value)) != nil}
  }
}
