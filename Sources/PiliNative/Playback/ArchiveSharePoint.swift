import Foundation

enum ArchiveSharePoint {
  static func archive(_ id:String,page:Int?,time:Double?=nil)->URL?{
    guard ArchiveNumber.av(id) != nil else{return nil}
    return link("/video/"+id+"/",page:page,time:time)
  }
  static func episode(_ id:Int64,course:Bool=false,time:Double?=nil)->URL?{
    guard id>0 else{return nil}
    return link((course ? "/cheese/play/ep":"/bangumi/play/ep")+String(id),page:nil,time:time)
  }
  private static func link(_ path:String,page:Int?,time:Double?)->URL?{
    var parts=URLComponents();parts.scheme="https";parts.host="www.bilibili.com";parts.path=path
    var query=[URLQueryItem]()
    if let page,page>1{query.append(.init(name:"p",value:String(page)))}
    if let time,time.isFinite,time>0,time<Double(Int32.max){
      let n=Int64((time*1000).rounded(.towardZero))
      if n>0{let second=String(n/1000),fraction=n%1000
        query.append(.init(name:"t",value:second+(fraction>0 ? "."+String(format:"%03d",fraction):"")))
      }
    }
    if !query.isEmpty{parts.queryItems=query}
    return parts.url
  }
}
