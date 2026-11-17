import CryptoKit
import Foundation

/// The public HD client protocol from the pinned PiliPlus source (AppSign + Constants).
enum MobileClientSigning {
  static let appKey = "dfca71928277209b"
  private static let appSecret = "b5475a8825547a4fc26c7d518eaaa02e"
  static let statistics = #"{"appId":5,"platform":3,"version":"2.0.1","abtest":""}"#
  static let userAgent = "Mozilla/5.0 BiliDroid/2.0.1 (bbcallen@gmail.com) os/android model/android_hd mobi_app/android_hd build/2001100 channel/master innerVer/2001100 osVer/15 network/2"
  private static let componentSafe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_.!~*'()")

  static func component(_ text: String) -> String {
    text.addingPercentEncoding(withAllowedCharacters: componentSafe) ?? ""
  }
  static func formEncoded(_ fields: [String: String]) -> String {
    fields.keys.sorted().map { component($0) + "=" + component(fields[$0]!) }.joined(separator: "&")
  }
  static func digest(_ text: String) -> String {
    Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  static func signed(_ fields: [String: String], timestamp: Int64 = Int64(Date().timeIntervalSince1970)) -> [String: String] {
    var result = fields
    result.removeValue(forKey: "sign")
    result["appkey"] = appKey
    result["ts"] = String(timestamp)
    result["sign"] = digest(formEncoded(result) + appSecret)
    return result
  }
}
