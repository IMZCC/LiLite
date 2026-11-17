import Foundation

final class APIRedirectPolicy: CertificateSessionDelegate, URLSessionDataDelegate, @unchecked Sendable {
  private let publicArtwork: Bool
  init(publicArtwork: Bool = false) {
    self.publicArtwork = publicArtwork
    super.init()
  }
  func urlSession(
    _ session: URLSession, dataTask: URLSessionDataTask,
    willCacheResponse proposed: CachedURLResponse,
    completionHandler: @escaping (CachedURLResponse?) -> Void
  ) {
    guard publicArtwork else {
      completionHandler(proposed)
      return
    }
    guard let r = proposed.response as? HTTPURLResponse,
      ArtworkCacheRules.admits(
        url: r.url, status: r.statusCode, mime: r.mimeType,
        cookie: r.value(forHTTPHeaderField: "Set-Cookie"),
        control: r.value(forHTTPHeaderField: "Cache-Control"))
    else {
      completionHandler(nil)
      return
    }
    completionHandler(proposed)
  }
  override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    let path = task.originalRequest?.url?.path ?? ""
    if let e = error as NSError?, e.domain == NSURLErrorDomain, e.code != NSURLErrorCancelled {
      DiagnosticJournal.network(path, "网络错误", e.code)
    } else if let r = task.response as? HTTPURLResponse, r.statusCode >= 400 {
      DiagnosticJournal.network(path, "HTTP", r.statusCode)
    }
  }
  override func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let src = task.originalRequest?.url, let dst = request.url,
      HTTP11Message.allowsRedirect(
        method: task.originalRequest?.httpMethod ?? "GET", from: src, to: dst)
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}
