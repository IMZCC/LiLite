import Foundation

struct ArchiveCacheDetails: Decodable {
  struct Rights: Decodable { let download: Int?, no_download: Int? }
  struct Part: Decodable, Identifiable {
    let cid: Int64
    var part: String?, page: Int?, duration: Int?
    var id: Int64 { cid }
  }
  struct Collection: Decodable {
    let id: Int64, title: String?, sections: [Section]?
    struct Section: Decodable, Identifiable { let id: Int64, title: String?, episodes: [Entry]? }
    struct Entry: Decodable, Identifiable {
      let id: Int64, title: String?, bvid: String?, aid: Int64?, cid: Int64?, pages: [Part]?
      struct Arc: Decodable { let pic: String?, aid: Int64?, bvid: String? }
      let arc: Arc?
      var archive: String? {
        if let bvid, ArchiveNumber.av(bvid) != nil { return bvid }
        if let b = arc?.bvid, ArchiveNumber.av(b) != nil { return b }
        return (aid ?? arc?.aid).flatMap(ArchiveNumber.bv)
      }
    }
  }
  let bvid: String, cid: Int64?, pages: [Part]?, rights: Rights?
  struct Owner: Decodable { let name: String? }
  var title: String?, pic: String?, aid: Int64?, duration: Int?, owner: Owner?,
    ugc_season: Collection?
  func authorize(_ archive: String, cid wanted: Int64) throws {
    guard bvid == archive, wanted > 0,
      cid == wanted || pages?.contains(where: { $0.cid == wanted }) == true
    else { throw ServiceError("分集信息已变化，请重新选择") }
    guard rights?.download == 1, rights?.no_download != 1 else {
      throw ServiceError("当前账号没有此稿件的缓存权限")
    }
  }
}

extension ArchiveCacheDetails {
  enum Keys: String, CodingKey {
    case bvid, cid, pages, rights, title, pic, aid, duration, owner, ugc_season
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    bvid = try c.decode(String.self, forKey: .bvid)
    cid = try c.decodeIfPresent(Int64.self, forKey: .cid)
    rights = try c.decodeIfPresent(Rights.self, forKey: .rights)
    pages = try c.decodeIfPresent([Part].self, forKey: .pages)
    title = try? c.decode(String.self, forKey: .title)
    pic = try? c.decode(String.self, forKey: .pic)
    aid = try? c.decode(Int64.self, forKey: .aid)
    duration = try? c.decode(Int.self, forKey: .duration)
    owner = try? c.decode(Owner.self, forKey: .owner)
    ugc_season = try? c.decode(Collection.self, forKey: .ugc_season)
  }
}
