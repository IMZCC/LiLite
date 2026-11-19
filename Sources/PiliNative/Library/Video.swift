import Foundation

struct Video: Decodable, Identifiable, Hashable {
  struct Rights: Decodable, Hashable { let is_stein_gate: Int? }
  struct FeedReason: Hashable, Decodable, Identifiable {
    let id: Int64, name: String
    let toast: String?
  }
  struct FeedMenu: Hashable, Decodable {
    let type: String
    let reasons: [FeedReason]?
  }
  var recommendationReason: String? = nil, recommendLink: String? = nil,
    recommendGoto: String? = nil
  var recommendResource: Int64? = nil, recommendMenu: [FeedMenu]? = nil
  struct Argue: Decodable, Hashable { let argue_msg: String? }
  struct IntroLine: Decodable, Hashable {
    let raw_text: String?, type: Int?, bizId: Int64?
    enum K: String, CodingKey { case raw_text, type, biz_id }
    init(from d: Decoder) throws {
      let c = try d.container(keyedBy: K.self)
      raw_text = try? c.decode(String.self, forKey: .raw_text)
      type = try? c.decode(Int.self, forKey: .type)
      bizId =
        (try? c.decode(Int64.self, forKey: .biz_id))
        ?? (try? c.decode(String.self, forKey: .biz_id)).flatMap(Int64.init)
    }
  }
  var argue_info: Argue? = nil, desc_v2: [IntroLine]? = nil, pubdate: Int64? = nil
  var is_upower_exclusive:Bool?=nil
  var copyright: Int? = nil
  var is_followed: Int? = nil
  var tname: String? = nil
  var rights: Rights? = nil
  var ugc_season: VideoCollection? = nil
  var season_id: Int64? = nil
  var staff: [VideoStaff]? = nil
  var aid: Int64? = nil
  var historyKey: String? = nil
  let bvid: String
  let title: String
  let pic: String
  let owner: Owner?
  let stat: Stat?
  let duration: Int?
  let desc: String?
  let cid: Int64?
  let pages: [Part]?
  var id: String { bvid }
  var cover: URL? { httpsURL(pic) }
  struct Owner: Decodable, Hashable {
    var mid: Int64? = nil
    let name: String?
    var face: String? = nil
    var avatar: URL? { face.flatMap(httpsURL) }
  }
  struct Stat: Decodable, Hashable {
    var like: Int? = nil, coin:Int?=nil, favorite:Int?=nil, share:Int?=nil, reply:Int?=nil
    let view: Int?
    let danmaku: Int?
  }
  struct Part: Decodable, Hashable, Identifiable {
    let cid: Int64
    var duration: Int? = nil
    let page: Int
    let part: String
    /// The part's opening frame, the fullscreen 选集 card's picture.
    var first_frame: String? = nil
    var id: Int64 { cid }
  }
}

func httpsURL(_ raw: String) -> URL? {
  guard var c = URLComponents(string: raw.hasPrefix("//") ? "https:" + raw : raw),
    c.host != nil, ["http", "https"].contains(c.scheme?.lowercased() ?? "")
  else { return nil }
  c.scheme = "https"
  return c.url
}

func clockText(_ seconds: Double) -> String {
  let t = seconds.isFinite ? max(0, Int(seconds)) : 0
  return t >= 3600
    ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60)
    : String(format: "%d:%02d", t / 60, t % 60)
}

extension RecommendationFilter {
  func allows(_ video: Video, from source: Source) -> Bool {
    includes(
      title: video.title, zone: video.tname, seconds: video.duration, views: video.stat?.view,
      likes: video.stat?.like, followed: video.is_followed == 1, creator: video.owner?.mid,
      source: source)
  }
}

struct PlaybackSource {
  var preview = false
  var volume: AudioMeasurements? = nil
  let url: URL
  let backups: [URL]
  let quality: Int
  let reference: URL
}

struct VideoStaff: Decodable, Hashable, Identifiable {
  struct VIP:Decodable,Hashable{let status:Int?,type:Int?}
  struct Official:Decodable,Hashable{let type:Int?,desc:String?}
  var face:String?=nil,vip:VIP?=nil,official:Official?=nil
  let mid:Int64,name:String?,title:String?
  private enum Keys:String,CodingKey{case mid,name,title,face,vip,official}
  init(from decoder:Decoder)throws{
    let fields=try decoder.container(keyedBy:Keys.self)
    mid=(try? fields.decode(Int64.self,forKey:.mid)) ?? (try? fields.decode(String.self,forKey:.mid)).flatMap(Int64.init) ?? 0
    name=try? fields.decode(String.self,forKey:.name);title=try? fields.decode(String.self,forKey:.title)
    face=try? fields.decode(String.self,forKey:.face);vip=try? fields.decode(VIP.self,forKey:.vip);official=try? fields.decode(Official.self,forKey:.official)
  }
  var id: Int64 { mid }
}
struct VideoCollection: Decodable, Hashable {
  var id: Int64? = nil
  var cover: String? = nil
  let title: String?, sections: [Part]?
  struct Part: Decodable, Hashable, Identifiable {
    let id: Int64, title: String?, episodes: [Entry]?
  }
  struct Entry: Decodable, Hashable, Identifiable {
    let id: Int64, title: String?, bvid: String?, arc: Arc?
    var cid:Int64?=nil,badge:String?=nil,pages:[Video.Part]?=nil,page:Video.Part?=nil
    struct Arc: Decodable, Hashable { let pic: String?, duration: Int? }
  }
}
