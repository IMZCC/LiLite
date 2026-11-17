import Foundation

struct ArchiveTag: Decodable, Identifiable {
  let tag_id: Int64?, tag_type: String?, tag_name: String?, music_id: String?
  var id: String { "\(tag_type ?? "")|\(tag_id ?? 0)|\(music_id ?? "")|\(tag_name ?? "")" }
  var route: SharedLink? {
    switch tag_type {
    case "bgm": return music_id.flatMap { id in
      var c = URLComponents(); c.scheme = "https"; c.host = "music.bilibili.com"; c.path = "/h5/music-detail"
      c.queryItems = [.init(name: "music_id", value: id)]
      return c.url.flatMap { SharedLink.parse($0.absoluteString) }
    }
    case "topic": return tag_id.flatMap { $0 > 0 ? .topic($0) : nil }
    default: return tag_name.flatMap { $0.isEmpty ? nil : .search($0) }
    }
  }
  var label: String {
    let name = tag_name ?? ""
    if tag_type == "bgm" { return "♫ " + (name.hasPrefix("发现") ? String(name.dropFirst(2)) : name) }
    return tag_type == "topic" ? "#" + name : name
  }
}

struct MusicRecord: Decodable {
  struct Artist: Decodable { let mid: Int64?, name: String?, face: String?, identity: String? }
  struct Point: Decodable, Equatable { let date: Int64, heat: Int64 }
  struct Heat: Decodable { let last_heat: Int64?, song_heat: [Point]? }
  struct Comments: Decodable { let oid: Int64?, page_type: Int?, nums: Int? }
  let music_title: String?, origin_artist: String?, origin_artist_list: String?, album: String?, music_source: String?, music_publish: String?
  let mv_aid: Int64?, mv_cid: Int64?, mv_bvid: String?, mv_cover: String?, wish_listen: Bool?, wish_count: Int?
  let listen_pv: Int64?, music_relation: Int64?, hot_song_heat: Heat?, music_comment: Comments?
  let artists_list: [Artist]?, achievement: [String]?, music_rank: String?, recreation_rank: String?
  var awards: [String] {
    var seen = Set<String>()
    return ((achievement ?? []) + [music_rank,recreation_rank].compactMap { $0 }).filter { !$0.isEmpty && seen.insert($0).inserted }
  }
  var trend: [Point] {
    var days = [Int64:Point]()
    for p in hot_song_heat?.song_heat ?? [] where p.date > 0 && p.heat >= 0 { if days[p.date] == nil { days[p.date] = p } }
    return days.values.sorted { $0.date < $1.date }
  }
  var mv: SharedLink? {
    guard let cid = mv_cid, cid > 0 else { return nil }
    if let bv = mv_bvid, let v = SharedLink.parse(bv), case .video = v { return .archivePart(v,cid) }
    if let av = mv_aid, av > 0 { return .archivePart(.archive(av,nil),cid) }; return nil
  }
  func wishFields(id: String) -> [String:String] { ["music_id":id,"state":wish_listen == true ? "2":"1"] }
  static func link(id: String) -> URL? {
    var c = URLComponents();c.scheme = "https"; c.host = "music.bilibili.com"; c.path = "/h5/music-detail"
    c.queryItems = [.init(name:"music_id", value:id)]
    guard let url = c.url, SharedLink.parse(url.absoluteString) == .music(id) else { return nil };return url
  }
}
struct MusicClips: Decodable {
  struct Clip: Decodable, Identifiable {
    struct Badge: Decodable { let name: String? }
    let bvid: String?, cid: Int64?, title: String?, cover: String?, up_nick_name: String?, duration: Int?, play: Int?, danmu: Int?, label_list: [Badge]?
    var id: String { "\(bvid ?? ""):\(cid ?? 0)" }
    var route: SharedLink? {
      guard let bv = bvid, let video = SharedLink.parse(bv), case .video = video else { return nil }
      if let cid, cid > 0 { return .archivePart(video,cid) }; return video
    }
  }
  let list: [Clip]?
  var videos: [Clip] {
    var seen = Set<String>(); return (list ?? []).filter { $0.route != nil && seen.insert($0.id).inserted }
  }
}
