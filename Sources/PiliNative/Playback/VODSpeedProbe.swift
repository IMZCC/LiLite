import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct VODSpeedProbe {
  let bytes: Int
  let bytesPerSecond: Double
  static func sample(_ url: URL, reference: URL, via transport: RangeTransport) async throws -> Self
  {
    let limit = 256 * 1024
    var request = URLRequest(url: url, timeoutInterval: 6)
    request.httpShouldHandleCookies = false
    request.setValue("bytes=0-\(limit-1)", forHTTPHeaderField: "Range")
    request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    request.setValue(reference.absoluteString, forHTTPHeaderField: "Referer")
    let r = request
    let start = ProcessInfo.processInfo.systemUptime
    let data = try await withThrowingTaskGroup(of: Data.self) { group in
      group.addTask { try await transport.read(r, limit: limit, acceptsShortResource: true) }
      group.addTask {
        try await Task.sleep(for: .seconds(8))
        throw URLError(.timedOut)
      }
      defer { group.cancelAll() }
      guard let response = try await group.next() else { throw CancellationError() }
      return response
    }
    try Task.checkCancellation()
    let elapsed = max(0.001, ProcessInfo.processInfo.systemUptime - start)
    return .init(bytes: data.count, bytesPerSecond: Double(data.count) / elapsed)
  }
}
