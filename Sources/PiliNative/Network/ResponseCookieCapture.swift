import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// A per-request receipt log, forwarding the existing session's complete redirect/TLS policy.
final class ResponseCookieCapture: CertificateSessionDelegate, @unchecked Sendable {
  private let forwarding: CertificateSessionDelegate
  private let lock = NSLock()
  private var received = [HTTPCookie]()
  init(forwarding: CertificateSessionDelegate) { self.forwarding = forwarding; super.init() }
  var cookies: [HTTPCookie] {
    lock.lock(); defer { lock.unlock() }
    return received
  }
  override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    forwarding.urlSession(session, task: task, didCompleteWithError: error)
  }
  override func urlSession(_ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void)
  {
    forwarding.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) { next in
      if next != nil {
        let rows = ResponseCookieOrigin.received(response)
        self.lock.lock(); self.received += rows; self.lock.unlock()
      }
      completionHandler(next)
    }
  }
  override func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
  {
    forwarding.urlSession(session, didReceive: challenge, completionHandler: completionHandler)
  }
  override func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
  {
    forwarding.urlSession(session, task: task, didReceive: challenge, completionHandler: completionHandler)
  }
}
