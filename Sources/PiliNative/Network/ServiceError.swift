import Foundation

struct ServiceError: LocalizedError {
  let message: String
  let code:Int?
  let continuation:URL?
  init(_ message: String,code:Int?=nil,continuation:URL?=nil) {self.message=message;self.code=code;self.continuation=continuation}
  static func searchCheck(_ keyword:String) -> ServiceError {
    var c=URLComponents();c.scheme="https";c.host="search.bilibili.com";c.path="/all"
    c.queryItems=[.init(name:"keyword",value:keyword)]
    return ServiceError("搜索需要验证",continuation:c.url)
  }
  static func readFailure(_ path:String, fields:[String:String], code:Int?, message:String) -> ServiceError {
    if code == -352, ["/x/web-interface/wbi/search/type","/x/web-interface/wbi/search/all/v2"].contains(path),
      let keyword=fields["keyword"] {return searchCheck(keyword)}
    return ServiceError(message,code:code)
  }
  var errorDescription: String? { message }
}
