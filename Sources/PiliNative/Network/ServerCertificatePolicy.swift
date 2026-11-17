import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if canImport(Security)
  import Security
#endif

enum ServerCertificatePolicy {
  static let key = "network.allowInvalidCertificates"
  static func enabled(_ defaults: UserDefaults = .standard) -> Bool {
    defaults.object(forKey: key) as? Bool ?? false
  }
  static func acceptsChallenge(
    method: String, hasServerTrust: Bool, failures: Int, defaults: UserDefaults = .standard
  ) -> Bool {
    enabled(defaults) && method == "NSURLAuthenticationMethodServerTrust" && hasServerTrust
      && failures == 0
  }
  static func credential(for challenge: URLAuthenticationChallenge) -> URLCredential? {
    #if canImport(Security)
      let space = challenge.protectionSpace
      guard acceptsChallenge(
        method: space.authenticationMethod, hasServerTrust: space.serverTrust != nil,
        failures: challenge.previousFailureCount), let trust = space.serverTrust
      else { return nil }
      return URLCredential(trust: trust)
    #else
      return nil
    #endif
  }
  static func respond(
    to challenge: URLAuthenticationChallenge,
    completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    if let credential = credential(for: challenge) { completion(.useCredential, credential) }
    else { completion(.performDefaultHandling, nil) }
  }
}

class CertificateSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  // Keep task callbacks virtual: FoundationNetworking's inherited protocol witnesses
  // otherwise resolve its default implementations instead of a subclass's handlers.
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {}
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) { completionHandler(request) }
  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {}
  func urlSession(
    _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) { ServerCertificatePolicy.respond(to: challenge, completion: completionHandler) }
  func urlSession(
    _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) { urlSession(session, didReceive: challenge, completionHandler: completionHandler) }
}
