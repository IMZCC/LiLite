import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A receiver only gets the chosen movie. CDN URLs, signed parameters and cookies stay off the LAN.
actor CastMediaSource {
  let transport = RangeTransport()
  private let urls: [URL], reference: URL
  private var preferred = 0, closed = false
  private let authorize: @Sendable () async throws -> Void
  init(urls: [URL], reference: URL, authorize: @escaping @Sendable () async throws -> Void = {}) {
    self.urls = urls
    self.reference = reference
    self.authorize = authorize
  }
  func range(_ lower: Int64, _ upper: Int64, total: Int64? = nil) async throws
    -> RangeTransport.Response
  {
    guard !closed, lower >= 0, upper >= lower, upper - lower < 1024 * 1024,
      total.map({ upper < $0 }) ?? true
    else { throw URLError(.badURL) }
    try await authorize()
    var lastError: Error = URLError(.cannotLoadFromNetwork)
    let indices = [preferred] + urls.indices.filter { $0 != preferred }
    for i in indices where urls.indices.contains(i) {
      try Task.checkCancellation()
      guard !closed else { throw CancellationError() }
      var r = URLRequest(url: urls[i])
      r.httpShouldHandleCookies = false
      r.setValue(reference.absoluteString, forHTTPHeaderField: "Referer")
      r.setValue(
        "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1",
        forHTTPHeaderField: "User-Agent")
      r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
      r.setValue("bytes=\(lower)-\(upper)", forHTTPHeaderField: "Range")
      do {
        let packet = try await transport.response(r, limit: Int(upper - lower + 1))
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
        guard packet.total < Int64.max, total.map({ $0 == packet.total }) ?? true else {
          throw URLError(.badServerResponse)
        }
        try await authorize()
        preferred = i
        return packet
      } catch {
        try Task.checkCancellation()
        try await authorize()
        if let e = error as? RangeHTTPStatus, [401, 403, 412, 429].contains(e.code) { throw e }
        lastError = error
      }
    }
    throw lastError
  }
  func access() async throws {
    guard !closed else { throw CancellationError() }
    try await authorize()
    try Task.checkCancellation()
  }
  func close() {
    closed = true
    transport.close()
  }
}
