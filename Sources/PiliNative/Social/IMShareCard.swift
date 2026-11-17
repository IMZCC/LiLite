import Foundation

struct IMShareCard: Identifiable {
  enum Kind: Int {
    case album = 2
    case video = 5
    case article = 6
    case dynamic = 11
    case episode = 16
    case live = 14
    var label: String {
      switch self {
      case .album: "相簿"
      case .video: "视频"
      case .article: "专栏"
      case .dynamic: "动态"
      case .episode: "番剧"
      case .live: "直播"
      }
    }
  }
  let kind: Kind, resource: String, title: String
  var author: String? = nil, authorID: String? = nil, thumb: URL? = nil, link: URL? = nil,
    subtitle: String? = nil
  var id: String { String(kind.rawValue) + ":" + resource }
  var messageType: Int { kind == .live ? 14 : 7 }
  var body: [String: Any] {
    var value: [String: Any]
    if kind == .live {
      value = [
        "source": "直播", "sourceID": resource, "title": title, "desc": title,
        "url": "https://live.bilibili.com/" + resource,
      ]
      value["cover"] = thumb?.absoluteString
      value["authorID"] = authorID
    } else {
      value = [
        "id": resource, "source": kind.rawValue, "title": kind == .article ? "- 哔哩哔哩专栏" : title,
        "headline": kind == .dynamic || kind == .album ? "" : title,
      ]
      value["thumb"] = thumb?.absoluteString
      value["author_id"] = authorID
      if kind == .episode {
        value["url"] = link?.absoluteString ?? "https://www.bilibili.com/bangumi/play/ep" + resource
        value["source_desc"] = subtitle ?? "番剧"
      }
    }
    value["author"] = author
    return value
  }
  init(
    _ kind: Kind, id: String, title: String, author: String? = nil, authorID: String? = nil,
    thumb: URL? = nil, link: URL? = nil, subtitle: String? = nil
  ) {
    self.kind = kind
    resource = id
    self.title = title
    self.author = author
    self.authorID = authorID
    self.thumb = thumb
    self.link = link
    self.subtitle = subtitle
  }
  static func incoming(_ type: Int?, _ data: [String: Any]) -> Self? {
    func text(_ k: String) -> String? { data[k] as? String ?? (data[k] as? NSNumber)?.stringValue }
    let kind: Kind?
    let id: String?
    if type == 14, text("source") == "直播" {
      kind = .live
      id = text("sourceID")
    } else if type == 7, let raw = text("source").flatMap(Int.init), raw != Kind.live.rawValue {
      kind = Kind(rawValue: raw)
      id = text("id")
    } else {
      return nil
    }
    guard let kind, let id, id.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int64(id), n > 0
    else { return nil }
    let display =
      [text("headline"), text("title"), text("desc")].compactMap { $0 }.first { !$0.isEmpty }
      ?? kind.label
    return .init(
      kind, id: id, title: display, author: text("author"),
      authorID: text("author_id") ?? text("authorID"),
      thumb: (text("thumb") ?? text("cover")).flatMap(httpsURL),
      link: text("url").flatMap(httpsURL), subtitle: text("source_desc"))
  }
  var route: SharedLink? {
    guard let n = Int64(resource), n > 0 else { return nil }
    switch kind {
    case .video: return .archive(n, nil)
    case .episode: return .episode(n)
    case .article: return .article(n)
    case .dynamic: return .dynamic(resource)
    case .live: return .room(n)
    case .album: return nil
    }
  }
}
