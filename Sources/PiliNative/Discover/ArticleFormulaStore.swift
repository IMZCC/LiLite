import Foundation

/// Formula responses contain no account data and are independent of the reader's theme.
actor ArticleFormulaStore {
  static let shared = ArticleFormulaStore()
  struct Result: Sendable {
    let data: Data
    let height: Double?
  }
  private final class Cached {
    let value: Result
    init(_ value: Result) { self.value = value }
  }
  private let cache = NSCache<NSString, Cached>()
  private init() {
    cache.countLimit = 64
    cache.totalCostLimit = 4 * 1024 * 1024
  }

  func image(_ formula: String) async throws -> Result? {
    try Task.checkCancellation()
    guard !formula.isEmpty, formula.utf8.count <= 6000 else { return nil }
    if let hit = cache.object(forKey: formula as NSString) { return hit.value }
    var url = URLComponents(string: "https://api.bilibili.com/x/web-frontend/mathjax/tex")!
    url.queryItems = [.init(name: "formula", value: formula)]
    guard let url = url.url else { return nil }
    var request = URLRequest(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 8)
    request.httpShouldHandleCookies = false
    let session = await BiliAPI.shared.session.native
    let (stream, response) = try await session.bytes(for: request)
    guard (response as? HTTPURLResponse)?.statusCode == 200,
      response.expectedContentLength <= 1024 * 1024
    else { return nil }
    var data = Data()
    for try await byte in stream {
      guard data.count < 1024 * 1024 else { return nil }
      if data.count & 4095 == 0 { try Task.checkCancellation() }
      data.append(byte)
    }
    guard let start = String(data: data.prefix(1536), encoding: .utf8), start.contains("<svg"),
      let root = start.range(of: #"<svg[^>]+>"#, options: .regularExpression)
    else { return nil }
    let header = String(start[root])
    let expression = try NSRegularExpression(
      pattern: #"\bheight\s*=\s*["']([0-9]+(?:\.[0-9]+)?)(ex|em|px|pt)?["']"#)
    var height: Double?
    if let match = expression.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
      let range = Range(match.range(at: 1), in: header), let number = Double(header[range]) {
      let unit = Range(match.range(at: 2), in: header).map { String(header[$0]) }
      height = min(220, max(24, number * (unit == "ex" ? 9 : unit == "em" ? 17 : 1) + 8))
    }
    try Task.checkCancellation()
    let value = Result(data: data, height: height)
    cache.setObject(Cached(value), forKey: formula as NSString, cost: data.count)
    return value
  }
}
