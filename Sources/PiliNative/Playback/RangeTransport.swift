import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

struct RangeHTTPStatus: LocalizedError {
  let code: Int
  var errorDescription: String? { "媒体服务器返回 HTTP \(code)" }
}

/// Shared by DASH indexes and fragments. Validate HTTP headers before accepting any body data.
final class RangeTransport: CertificateSessionDelegate, URLSessionDataDelegate, @unchecked Sendable {
  struct Response { let data: Data, total: Int64, mimeType: String? }
  private final class Transfer {
    let acceptsShortResource: Bool
    let limit: Int, request: String, continuation: CheckedContinuation<Response, Error>
    var bytes = Data(), range: MediaRange?, mimeType: String?
    init(
      _ limit: Int, _ request: String, _ acceptsShortResource: Bool,
      _ continuation: CheckedContinuation<Response, Error>
    ) {
      self.acceptsShortResource = acceptsShortResource
      self.limit = limit
      self.request = request
      self.continuation = continuation
    }
  }
  private final class CancelLink: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private weak var task: URLSessionTask?
    func start(_ t: URLSessionTask) {
      lock.lock()
      task = t
      let cancel = cancelled
      lock.unlock()
      t.resume()
      if cancel { t.cancel() }
    }
    func cancel() {
      lock.lock()
      cancelled = true
      let t = task
      lock.unlock()
      t?.cancel()
    }
  }
  private var session: URLSession!
  private let lock = NSLock()
  private var tasks: [Int: Transfer] = [:]
  override init() {
    super.init()
    let c = URLSessionConfiguration.ephemeral
    c.urlCache = nil
    c.timeoutIntervalForRequest = 20
    c.urlCredentialStorage = nil
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 1
    session = URLSession(configuration: c, delegate: self, delegateQueue: q)
  }
  // Delegate callbacks run on a serial queue. The lock protects registration and removal
  // relative to callers, while only the delegate queue mutates individual transfer buffers.
  private func transfer(_ id: Int, remove: Bool = false) -> Transfer? {
    lock.lock()
    defer { lock.unlock() }
    return remove ? tasks.removeValue(forKey: id) : tasks[id]
  }
  func read(_ r: URLRequest, limit: Int, acceptsShortResource: Bool = false) async throws -> Data {
    try await response(r, limit: limit, acceptsShortResource: acceptsShortResource).data
  }
  func response(_ r: URLRequest, limit: Int, acceptsShortResource: Bool = false) async throws -> Response {
    guard limit > 0, limit <= 48 * 1024 * 1024, let request = r.value(forHTTPHeaderField: "Range")
    else { throw URLError(.badURL) }
    let owner = CancelLink()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { cont in
        let task = session.dataTask(with: r)
        lock.lock()
        tasks[task.taskIdentifier] = Transfer(limit, request, acceptsShortResource, cont)
        lock.unlock()
        owner.start(task)
      }
    } onCancel: {
      owner.cancel()
    }
  }
  func close() { session.invalidateAndCancel() }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    let id = dataTask.taskIdentifier
    guard let t = transfer(id) else {
      completionHandler(.cancel)
      return
    }
    if let h = response as? HTTPURLResponse, h.statusCode != 206 {
      transfer(id, remove: true)?.continuation.resume(throwing: RangeHTTPStatus(code: h.statusCode))
      completionHandler(.cancel)
      return
    }
    guard let h = response as? HTTPURLResponse, h.statusCode == 206,
      let rng = MediaRange(
        field: h.value(forHTTPHeaderField: "Content-Range"), request: t.request,
        declared: h.expectedContentLength),
      rng.length == t.limit
        || (t.acceptsShortResource && rng.length < t.limit && rng.length == rng.total)
    else {
      transfer(id, remove: true)?.continuation.resume(throwing: URLError(.badServerResponse))
      completionHandler(.cancel)
      return
    }
    t.mimeType = h.mimeType
    t.range = rng
    t.bytes.reserveCapacity(t.limit)
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let id = dataTask.taskIdentifier
    guard let t = transfer(id) else { return }
    guard t.range?.accept(data.count) == true else {
      transfer(id, remove: true)?.continuation.resume(throwing: URLError(.badServerResponse))
      dataTask.cancel()
      return
    }
    t.bytes.append(data)
  }
  override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    guard let t = transfer(task.taskIdentifier, remove: true) else { return }
    if let error {
      t.continuation.resume(throwing: error)
    } else if let range = t.range, range.complete {
      t.continuation.resume(returning: .init(data: t.bytes, total: range.total, mimeType: t.mimeType))
    } else {
      t.continuation.resume(throwing: URLError(.networkConnectionLost))
    }
  }
}
