import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

// Each operation is tied to a single descriptor's LAN host. No cookies, URL credentials,
// redirects or device-instructed remote hosts enter this channel.
private final class CastRequest: CertificateSessionDelegate, URLSessionDataDelegate, @unchecked Sendable {
  private let lock = NSLock(), limit: Int
  private var task: URLSessionDataTask?, session: URLSession?,
    done: CheckedContinuation<(Int, Data), Error>?, cancelled = false
  private var data = Data(), status = 0
  init(_ limit: Int) { self.limit = limit }
  func run(_ request: URLRequest) async throws -> (Int, Data) {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { cont in
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        cfg.urlCredentialStorage = nil
        cfg.urlCache = nil
        cfg.timeoutIntervalForRequest = 4
        cfg.timeoutIntervalForResource = 6
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
        let task = session.dataTask(with: request)
        lock.lock()
        if cancelled {
          lock.unlock()
          session.invalidateAndCancel()
          cont.resume(throwing: CancellationError())
          return
        }
        self.session = session
        self.task = task
        done = cont
        lock.unlock()
        task.resume()
      }
    } onCancel: {
      self.cancel()
    }
  }
  private func finish(_ result: Result<(Int, Data), Error>) {
    lock.lock()
    let cont = done
    let s = session
    done = nil
    task = nil
    session = nil
    lock.unlock()
    s?.finishTasksAndInvalidate()
    cont?.resume(with: result)
  }
  private func cancel() {
    lock.lock()
    cancelled = true
    let work = task
    lock.unlock()
    work?.cancel()
  }
  override func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(nil) }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let h = response as? HTTPURLResponse, h.expectedContentLength <= Int64(limit) else {
      completionHandler(.cancel)
      finish(.failure(CastProblem.reply))
      return
    }
    status = h.statusCode
    completionHandler(.allow)
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive packet: Data) {
    guard packet.count <= limit - data.count else {
      dataTask.cancel()
      finish(.failure(CastProblem.reply))
      return
    }
    data.append(packet)
  }
  override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { finish(.failure(error)) } else { finish(.success((status, data))) }
  }
}
struct CastHTTP: Sendable {
  let fixture: Bool
  init(fixture: Bool = false) { self.fixture = fixture }
  func request(
    _ url: URL, method: String = "GET", body: Data? = nil, soap: String? = nil,
    limit: Int = 128 * 1024
  ) async throws -> (Int, Data) {
    guard CastAddress.safe(url, fixture: fixture) else { throw CastProblem.address }
    var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 5)
    r.httpShouldHandleCookies = false
    r.httpMethod = method
    r.httpBody = body
    if let soap {
      r.setValue("\"" + soap + "\"", forHTTPHeaderField: "SOAPAction")
      r.setValue("text/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
    }
    let res = try await CastRequest(limit).run(r)
    try Task.checkCancellation()
    return res
  }
  func device(_ url: URL, alias: String? = nil) async throws -> CastDevice {
    let (s, d) = try await request(url, limit: 512 * 1024)
    guard s == 200 else { throw CastProblem.description }
    return try CastProtocol.device(d, url: url, fixture: fixture, alias: alias)
  }
}
struct CastClient {
  let device: CastDevice, http: CastHTTP
  var av = CastCapabilities(), rc = CastCapabilities()
  init(_ device: CastDevice, http: CastHTTP = CastHTTP()) {
    self.device = device
    self.http = http
  }
  mutating func prepare() async {
    func caps(_ s: CastService?) async -> CastCapabilities {
      guard let u = s?.scpd, let (status, d) = try? await http.request(u, limit: 512 * 1024),
        status == 200
      else { return .init() }
      return (try? CastProtocol.capabilities(d)) ?? .init()
    }
    let t = await caps(device.transport)
    let r = await caps(device.render)
    av = t
    rc = r
  }
  func supports(_ a: CastAction) -> Bool {
    a.kind == .render ? device.render != nil && rc.supports(a) : av.supports(a)
  }
  func call(_ action: CastAction, _ fields: [(String, String)] = []) async throws -> [String:
    String]
  {
    guard supports(action), let svc = (action.kind == .render ? device.render : device.transport)
    else { throw CastProblem.unsupported }
    let (status, d) = try await http.request(
      svc.control, method: "POST",
      body: CastProtocol.envelope(action, service: svc, fields: fields),
      soap: svc.urn + "#" + action.rawValue)
    return try CastProtocol.reply(d, status: status, action: action, service: svc)
  }
}
