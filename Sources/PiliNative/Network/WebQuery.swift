import Foundation

enum WebQuery {
  struct Keys: Decodable {
    struct Pair: Decodable { let img_url, sub_url: URL }
    let wbi_img: Pair
  }
  static func mix(_ img: Keys.Pair) throws -> String {
    let chars = Array(
      img.img_url.deletingPathExtension().lastPathComponent
        + img.sub_url.deletingPathExtension().lastPathComponent)
    let offsets = [
      46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49, 33, 9, 42, 19,
      29, 28, 14, 39, 12, 38, 41, 13,
    ]
    guard chars.count >= 64 else { throw ServiceError("视频服务参数无效") }
    return String(offsets.map { chars[$0] })
  }
  static func signed(_ query: [String: String], mix: String, digest: (Data) -> String) -> [String:
    String]
  {
    var result = query
    result["wts"] = String(Int(Date().timeIntervalSince1970))
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    let canonical = result.keys.sorted().map { k in
      let value = (result[k] ?? "").filter { !"'!()*".contains($0) }
      return "\(k)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")"
    }.joined(separator: "&")
    result["w_rid"] = digest(Data((canonical + mix).utf8))
    return result
  }
}
