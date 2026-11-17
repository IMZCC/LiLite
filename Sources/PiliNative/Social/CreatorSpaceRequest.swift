import Foundation

enum CreatorSpaceRequest {
  // Match MemberHttp.space in the source client; an iPhone-only query returns -400.
  static func fields(_ mid: Int64) -> [String: String] {
    [
      "vmid": String(mid), "build": "8430300", "version": "8.43.0",
      "c_locale": "zh_CN", "s_locale": "zh_CN", "channel": "master",
      "mobi_app": "android", "platform": "android",
      "statistics": #"{"appId":1,"platform":3,"version":"8.43.0","abtest":""}"#,
    ]
  }
}
