import Foundation

enum CastBonjourLocation {
  static func description(peer:String,name:String?,port:Int,tcp:Bool,fields:[String:String])->URL? {
    guard (1...65535).contains(port) else{return nil}
    var c=URLComponents();c.scheme="http";c.host=peer.contains(":") ? "[\(peer)]":peer;c.port=port
    guard let base=c.url,CastAddress.safe(base) else{return nil}
    let value=fields["location"] ?? fields["url"] ?? fields["path"] ?? (tcp ? "/":nil)
    guard let value,!value.isEmpty,value.utf8.count<=2048,!value.hasPrefix("//"),
      let candidate=URL(string:value,relativeTo:base)?.absoluteURL,
      var actual=URLComponents(url:candidate,resolvingAgainstBaseURL:false),
      let host=CastAddress.host(candidate),host==peer || (name != nil && host==name && host.hasSuffix(".local")),
      candidate.scheme=="http",candidate.user==nil,candidate.password==nil,candidate.fragment==nil
    else{return nil}
    actual.host=c.host
    guard let out=actual.url,CastAddress.safe(out) else{return nil}
    return out
  }
}
