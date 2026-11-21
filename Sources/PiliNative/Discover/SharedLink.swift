import Foundation

enum AppLibraryPage: String, Hashable { case root, history, liveDirectory, ranking, login, downloads }
enum SharedLink: Hashable {
  case appPage(AppLibraryPage), search(String), favorites(String), relations(Int64, Bool)
  case course(Int64, Bool)
  case album(Int64), cofollow(Int64), disclosure(Int64), browser(URL), sharedPlaylist(Int64, String)
  indirect case commentOn(SharedLink, Int64, Int64?)
  case song(Int64)
  case video(String, Int?)
  case archive(Int64, Int?)
  indirect case positioned(SharedLink, Double), archivePart(SharedLink, Int64)
  case season(Int64)
  case episode(Int64)
  case creator(Int64)
  case room(Int64)
  case dynamic(String)
  case article(Int64)
  case articleList(Int64)
  case opus(String)
  case community(Int64)
  case topic(Int64)
  case favoriteFolder(Int64), subscriptionSeason(Int64)
  case music(String)
  case match(Int64)
  case vote(Int64), contextVote(Int64, Int64)
  case replies(Int64, Int, Int64, Int64?)
  var opensVideoDetail: Bool {
    switch self {
    case .video, .archive, .replies(_, 1, _, _): true
    case .positioned(let page, _), .archivePart(let page, _), .commentOn(let page, _, _):
      page.opensVideoDetail
    default: false
    }
  }
  static func parse(_ input: String) -> Self? {
    let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
    let input: String
    if raw.hasPrefix("//") { input = "https:" + raw }
    else if !raw.contains("://"), raw.prefix(while: { $0 != "/" }).lowercased().hasSuffix("bilibili.com") { input = "https://" + raw }
    else { input = raw }
    guard var target = parseTarget(input) else { return nil }
    let base = target
    let fields = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines))?.queryItems ?? []
    func value(_ key: String) -> String? {
      let values = fields.filter { $0.name == key }
      return values.count == 1 ? values[0].value : nil
    }
    func positive(_ text: String?) -> Int64? {
      guard let text, !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }),
        let n = Int64(text), n > 0 else { return nil }
      return n
    }
    switch base {
    case .video, .archive, .episode, .course:
      if let cid = positive(value("cid")) {
        switch target { case .video, .archive: target = .archivePart(target, cid); default: break }
      }
      let time: Double?
      if let raw = value("start_progress") { time = Int64(raw).flatMap { $0 >= 0 ? Double($0) / 1000 : nil } }
      else if let raw = value("dm_progress") { time = Int64(raw).flatMap { $0 >= 0 ? max(0, Double($0) / 1000 - 3) : nil } }
      else { time = value("t").flatMap(Double.init) }
      if let time, time.isFinite, time >= 0, time < Double(Int32.max) { target = .positioned(target, time) }
    default: break
    }
    if let root = positive(value("comment_root_id")) {
      switch base {
      case .archive, .video, .episode, .course(_, true), .dynamic, .opus, .album, .article:
        return .commentOn(target, root, positive(value("comment_secondary_id")))
      default: break
      }
    }
    return target
  }
  private static func parseTarget(_ input: String) -> Self? {
    let s = input.trimmingCharacters(in: .whitespacesAndNewlines)
    func numeric(_ v: String) -> Int64? {
      guard !v.isEmpty, v.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }), let n = Int64(v), n > 0 else {
        return nil
      }
      return n
    }
    func music(_ v: String) -> Self? {
      guard v.hasPrefix("MA"), v.count > 2, v.utf8.count <= 96,
        v.dropFirst(2).utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) })
      else { return nil }; return .music(v)
    }
    func token(_ v: String, _ page: Int?) -> Self? {
      if v.count == 12, v.hasPrefix("BV"),
        v.dropFirst(2).utf8.allSatisfy({
          ($0 >= 65 && $0 <= 90) || ($0 >= 97 && $0 <= 122) || ($0 >= 48 && $0 <= 57)
        })
      {
        return .video(v, page)
      }
      guard v.count > 2, let n = numeric(String(v.dropFirst(2))) else { return nil }
      switch v.lowercased().prefix(2) {
      case "au": return .song(n)
      case "av": return .archive(n, page)
      case "ss": return .season(n)
      case "ep": return .episode(n)
      case "cv": return .article(n)
      case "rl": return .articleList(n)
      default: return nil
      }
    }
    if let r = token(s, nil) { return r }
    guard let c = URLComponents(string: s), let host = c.host?.lowercased(), c.user == nil,
      c.password == nil, c.port == nil
    else { return nil }
    let parts = c.path.split(separator: "/").map(String.init)
    let last = parts.last ?? ""
    func query(_ key: String) -> String {
      let values = (c.queryItems ?? []).filter { $0.name == key }
      return values.count == 1 ? values[0].value ?? "" : ""
    }
    func vote() -> Self? {
      guard let id = numeric(query("vote_id")) else { return nil }
      return numeric(query("dynamic_id")).map { .contextVote(id, $0) } ?? .vote(id)
    }
    let page = numeric(query("p")).flatMap(Int.init(exactly:))
    let topicPage = parts == ["topic-detail"] || parts == ["v", "topic", "detail"] || parts == ["topic", "detail"] || parts == ["topic"]
    if topicPage, ["www.bilibili.com", "bilibili.com", "m.bilibili.com"].contains(host),
      c.scheme == "http" || c.scheme == "https" || (c.scheme == "bilibili" && host == "m.bilibili.com") {
      return numeric(query("topic_id")).map(Self.topic)
    }
    if c.scheme == "bilibili" {
      switch host {
      case "root": return .appPage(.root)
      case "search": return .search(String(query("keyword").prefix(256)))
      case "history": return .appPage(.history)
      case "download": return .appPage(.downloads)
      case "rank": return .appPage(.ranking)
      case "livearea": return .appPage(.liveDirectory)
      case "login": return (c.queryItems ?? []).isEmpty && parts.isEmpty ? .appPage(.login) : nil
      case "main": return parts == ["favorite"] ? .favorites(query("tab")) : nil
      case "cheese": return parts.first == "season" ? numeric(last).map { .course($0, false) } : nil
      case "music": return parts.first == "playlist" ? numeric(last).map(Self.favoriteFolder) : nil
      case "medialist":
        return numeric(last.hasPrefix("ml") ? String(last.dropFirst(2)) : last).map(Self.favoriteFolder)
      case "comment":
        guard parts.count >= 4, ["detail", "msg_fold"].contains(parts[0]),
          let type = numeric(parts[1]).flatMap(Int.init(exactly:)), let oid = numeric(parts[2]),
          let root = numeric(parts[3])
        else { return nil }
        if [11,12].contains(type), let entry = URLComponents(string: query("enterUri")),
          entry.user == nil, entry.password == nil, entry.port == nil {
          let path = entry.path.split(separator: "/")
          if entry.scheme == "bilibili", entry.host == "following", path.count == 2, path[0] == "detail",
            let id = numeric(String(path[1])) { return .commentOn(.dynamic(String(id)), root, numeric(query("anchor"))) }
        }
        return .replies(oid, type, root, numeric(query("anchor")))
      case "video":
        return numeric(last).map { .archive($0, page) } ?? token(last, page)
      case "pgc", "bangumi":
        guard parts.first == "season" else { return nil }
        return parts.contains("ep")
          ? numeric(last).map(Self.episode) : numeric(last).map(Self.season)
      case "space":
        if parts.count == 2, parts.first == "realname" { return numeric(last).map(Self.disclosure) }
        return parts.count == 1 ? numeric(last).map(Self.creator) : nil
      case "album": return numeric(last).map(Self.album)
      case "browser":
        guard parts.isEmpty, let u = URLComponents(string:query("url")), u.scheme == "https" || u.scheme == "http",
          let domain = u.host, !domain.isEmpty, u.user == nil, u.password == nil, let url = u.url else { return nil }
        return .browser(url)
      case "live": return numeric(last).map(Self.room)
      case "article": return numeric(last).map(Self.article)
      case "opus": return numeric(last).map { query("type") == "2" ? .album($0) : .opus(String($0)) }
      case "following":
        guard parts.first == "detail" else { return nil }
        if last.lowercased().hasPrefix("cv") { return numeric(String(last.dropFirst(2))).map(Self.article) }
        return numeric(last).map { query("type") == "2" ? .album($0) : .dynamic(String($0)) }
      default: return nil
      }
    }
    if c.scheme == "piliplus" {
      switch host {
      case "audio": return numeric(last).map(Self.song)
      case "video": return token(last, page)
      case "season": return numeric(last).map(Self.season)
      case "episode": return numeric(last).map(Self.episode)
      case "user": return numeric(last).map(Self.creator)
      case "live": return numeric(last).map(Self.room)
      case "dynamic": return numeric(last).map { .dynamic(String($0)) }
      case "article": return numeric(last).map(Self.article)
      case "music": return music(last) ?? numeric(last).map { .music(String($0)) }
      case "match": return numeric(last).map(Self.match)
      case "vote": return numeric(last).map(Self.vote)
      default: return nil
      }
    }
    guard c.scheme == "https" || c.scheme == "http" else { return nil }
    switch host {
    case "t.bilibili.com":
      if parts.first == "vote" { return vote() }
      return numeric(last).map { query("type") == "2" ? .album($0) : .dynamic(String($0)) }
    case "search.bilibili.com": return .search(String(query("keyword").prefix(256)))
    case "space.bilibili.com":
      let profileID = parts == ["h5","follow"] ? numeric(query("mid")) : parts.first.flatMap(numeric)
      if let mid = profileID, parts == ["h5","follow"] || (parts.count == 3 && parts[1] == "relation") {
        switch parts == ["h5","follow"] ? query("type") : last {
        case "fans": return .relations(mid,true)
        case "follow": return .relations(mid,false)
        case "followed": return .cofollow(mid)
        default: return .creator(mid)
        }
      }
      if let uid = parts.first.flatMap(numeric), let end = parts.last, ["fans", "follow"].contains(end) { return .relations(uid, end == "fans") }
      if parts.count >= 2, numeric(parts[0]) != nil {
        if parts.count == 3, parts[1] == "lists", let id = numeric(parts[2]) { return .subscriptionSeason(id) }
        if (parts[1] == "lists" || Array(parts.dropFirst()) == ["channel","collectiondetail"]),
          let id = numeric(query("sid")) { return .subscriptionSeason(id) }
      }
      return parts.first.flatMap(numeric).map(Self.creator)
    case "live.bilibili.com": return numeric(last).map(Self.room)
    case "music.bilibili.com": return last.contains("music-detail") ? music(query("music_id")) : nil
    case "www.bilibili.com", "bilibili.com", "m.bilibili.com":
      let contentParts = ["h5","mobile","v"].contains(parts.first ?? "") ? Array(parts.dropFirst()) : parts
      if contentParts == ["vote"] { return vote() }
      if contentParts == ["comment","sub"], let oid = numeric(query("oid")), let root = numeric(query("root")) {
        let second = numeric(query("comment_secondary_id"))
        if ["11","12","17"].contains(query("pageType")) { return .commentOn(.dynamic(String(oid)),root,second) }
        return .commentOn(.archive(oid,nil),root,second)
      }
      if ["match","game"].contains(contentParts.first ?? ""),
        contentParts.contains("singledata") || (contentParts.contains("data") && contentParts.contains("detail")) {
        return contentParts.reversed().compactMap(numeric).first.map(Self.match)
      }
      if contentParts.first == "playlist", let video = token(query("bvid"),nil) ?? contentParts.dropFirst().compactMap({ token($0,nil) }).first, case .video(let bv,_) = video {
        if let name = contentParts.dropFirst().first(where: { $0.lowercased().hasPrefix("pl") }), let folder = numeric(String(name.dropFirst(2))) {
          return .sharedPlaylist(folder,bv)
        }
        return video
      }
      let noteParts=["h5","mobile","v"].contains(parts.first ?? "") ? Array(parts.dropFirst()):parts
      if noteParts==["note"] || noteParts==["note-app"] || noteParts==["note","view"] || noteParts==["note-app","view"]{
        guard c.queryItems?.filter({$0.name=="cvid"}).count==1 else{return nil};return numeric(query("cvid")).map(Self.article)
      }
      switch contentParts.first {
      case "medialist":
        guard last.hasPrefix("ml") else { return nil }
        return numeric(String(last.dropFirst(2))).map(Self.favoriteFolder)
      case "cheese":
        guard let n = numeric(String(last.dropFirst(2))),
          last.hasPrefix("ep") || last.hasPrefix("ss")
        else { return nil }
        return .course(n, last.hasPrefix("ep"))
      case "video":
        return token(last, page)
      case "bangumi", "read", "audio": return token(last, page)
      case "history": return .appPage(.history)
      case "popular": return parts.contains("rank") ? .appPage(.ranking) : nil
      case "bubble", "tribee": return numeric(last).map(Self.community)
      case "opus": return numeric(last).map { query("type") == "2" ? .album($0) : .opus(String($0)) }
      case "dynamic": return numeric(last).map { query("type") == "2" ? .album($0) : .dynamic(String($0)) }
      case "space": return numeric(last).map(Self.creator)
      case "match": return numeric(last).map(Self.match)
      default: return nil
      }
    default: return nil
    }
  }
}
