import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Fetch only playlists and selected clear segments from the origins supplied by the live service.
/// Response limits are enforced as bytes arrive, including for chunked HTTP responses.
final class LiveHLSFetch: CertificateSessionDelegate, URLSessionDataDelegate, @unchecked Sendable {
  struct Body { let url: URL, data: Data }
  private final class Request {
    let address: LiveHLSPlaylist.Resource, limit: Int, done: CheckedContinuation<Body, Error>
    var payload = Data(), url: URL?
    init(
      _ address: LiveHLSPlaylist.Resource, _ limit: Int, _ done: CheckedContinuation<Body, Error>
    ) {
      self.address = address
      self.limit = limit
      self.done = done
    }
  }
  private final class Link: @unchecked Sendable {
    let lock = NSLock()
    var stopped = false
    weak var task: URLSessionTask?
    func start(_ t: URLSessionTask) {
      lock.lock()
      task = t
      let cancel = stopped
      lock.unlock()
      t.resume()
      if cancel { t.cancel() }
    }
    func cancel() {
      lock.lock()
      stopped = true
      let t = task
      lock.unlock()
      t?.cancel()
    }
  }
  let origins: Set<String>
  private let room: Int64, lock = NSLock()
  private var pending: [Int: Request] = [:], session: URLSession!, closed = false
  init(room: Int64, origins: Set<String>, configuration: URLSessionConfiguration = .ephemeral) {
    self.room = room
    self.origins = origins
    super.init()
    let cfg = configuration
    cfg.httpShouldSetCookies = false
    cfg.httpCookieStorage = nil
    cfg.urlCredentialStorage = nil
    cfg.urlCache = nil
    cfg.timeoutIntervalForRequest = 16
    cfg.timeoutIntervalForResource = 20
    let q = OperationQueue()
    q.maxConcurrentOperationCount = 1
    session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
  }
  func read(_ resource: LiveHLSPlaylist.Resource, limit: Int) async throws -> Body {
    try Task.checkCancellation()
    guard let h = LiveHLSPlaylist.origin(resource.url), origins.contains(h), limit > 0,
      limit <= 32 * 1024 * 1024,
      resource.bytes.map({ $0.count <= limit }) ?? true
    else { throw LivePlaylistError.malformed }
    let link = Link()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { done in
        var r = URLRequest(url: resource.url)
        r.httpShouldHandleCookies = false
        r.setValue("https://live.bilibili.com/\(room)", forHTTPHeaderField: "Referer")
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        r.setValue(
          "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1",
          forHTTPHeaderField: "User-Agent")
        if let b = resource.bytes {
          r.setValue("bytes=\(b.lower)-\(b.upper)", forHTTPHeaderField: "Range")
        }
        lock.lock()
        guard !closed else {
          lock.unlock()
          done.resume(throwing: CancellationError())
          return
        }
        let t = session.dataTask(with: r)
        pending[t.taskIdentifier] = Request(resource, limit, done)
        lock.unlock()
        link.start(t)
      }
    } onCancel: {
      link.cancel()
    }
  }
  func close() {
    lock.lock()
    guard !closed else {
      lock.unlock()
      return
    }
    closed = true
    lock.unlock()
    session.invalidateAndCancel()
  }
  private func get(_ id: Int, remove: Bool = false) -> Request? {
    lock.lock()
    defer { lock.unlock() }
    return remove ? pending.removeValue(forKey: id) : pending[id]
  }
  override func urlSession(
    _ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection res: HTTPURLResponse,
    newRequest r: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let dest = r.url, LiveHLSPlaylist.origin(dest).map(origins.contains) == true else {
      completionHandler(nil)
      return
    }
    completionHandler(r)
  }
  func urlSession(
    _ s: URLSession, dataTask t: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    let id = t.taskIdentifier
    guard let f = get(id) else {
      completionHandler(.cancel)
      return
    }
    func no(_ error: Error) {
      get(id, remove: true)?.done.resume(throwing: error)
      completionHandler(.cancel)
    }
    guard let h = response as? HTTPURLResponse, let url = h.url,
      LiveHLSPlaylist.origin(url).map(origins.contains) == true
    else {
      no(LivePlaylistError.malformed)
      return
    }
    if [401, 403, 412, 429].contains(h.statusCode) {
      no(LivePlaylistError.denied(h.statusCode))
      return
    }
    if let b = f.address.bytes {
      guard h.statusCode == 206,
        let v = MediaRange(
          field: h.value(forHTTPHeaderField: "Content-Range"),
          request: "bytes=\(b.lower)-\(b.upper)", declared: h.expectedContentLength),
        v.length == b.count
      else {
        no(LivePlaylistError.malformed)
        return
      }
    } else if h.statusCode != 200 {
      no(URLError(.badServerResponse))
      return
    }
    guard h.expectedContentLength <= f.limit else {
      no(URLError(.dataLengthExceedsMaximum))
      return
    }
    f.url = url
    completionHandler(.allow)
  }
  func urlSession(_ s: URLSession, dataTask t: URLSessionDataTask, didReceive data: Data) {
    let id = t.taskIdentifier
    guard let f = get(id) else { return }
    guard data.count <= f.limit - f.payload.count else {
      get(id, remove: true)?.done.resume(throwing: URLError(.dataLengthExceedsMaximum))
      t.cancel()
      return
    }
    f.payload.append(data)
  }
  override func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
    guard let f = get(t.taskIdentifier, remove: true) else { return }
    if let e = error {
      f.done.resume(throwing: e)
    } else if let url = f.url, !f.payload.isEmpty,
      f.address.bytes.map({ $0.count == f.payload.count }) ?? true
    {
      f.done.resume(returning: Body(url: url, data: f.payload))
    } else {
      f.done.resume(throwing: LivePlaylistError.malformed)
    }
  }
}
