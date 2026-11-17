import Foundation

struct SponsorSource: Identifiable, Equatable {
  let bvid:String, cid:Int64, youtube:String, original:URL, seconds:Int
  var id:String { "\(bvid):\(cid):\(youtube)" }
  init?(archive:String,cid:Int64?,duration:Double?,link:URL) {
    guard let cid,cid>0, let duration,duration.isFinite,duration>0,duration<Double(Int32.max),
      case .video = SharedLink.parse(archive), let yt=Self.youtubeID(link) else{return nil}
    self.bvid=archive;self.cid=cid;youtube=yt;original=link;seconds=max(1,Int(duration.rounded()))
  }
  static func youtubeID(_ u:URL)->String? {
    guard let c=URLComponents(url:u,resolvingAgainstBaseURL:false),["http","https"].contains(c.scheme?.lowercased() ?? ""),
      let host=c.host?.lowercased(),c.port==nil,c.user==nil,c.password==nil else{return nil}
    let parts=c.path.split(separator:"/").map(String.init); let value:String?
    switch host {
    case "youtu.be": value = parts.count==1 ? parts[0]:nil
    case "youtube.com","www.youtube.com","m.youtube.com","music.youtube.com":
      if parts==["watch"] {let ids=(c.queryItems ?? []).filter{$0.name=="v"};value=ids.count==1 ? ids[0].value:nil}
      else if parts.count==2,["v","e","embed","shorts","live"].contains(parts[0]){ value=parts[1] } else {return nil}
    default:return nil
    }
    return value.flatMap { validID($0) ? $0:nil }
  }
  static func validID(_ s:String)->Bool {
    s.utf8.count==11 && s.utf8.allSatisfy{(48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0==45 || $0==95}
  }
  var lookup:[String:String]{ ["videoID":bvid,"cid":String(cid)] }
  func fields(identity:String)->[String:Any] {["bvID":bvid,"cid":String(cid),"ytbID":youtube,"userID":identity,"biliDuration":seconds]}
}

struct SponsorLinkRecord: Decodable { let ytbID:String? }
struct SponsorLinkReceipt: Decodable { let UUID:String? }
