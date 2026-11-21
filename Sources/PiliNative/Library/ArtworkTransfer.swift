import Foundation

/// URLSession delivers body chunks on its serial delegate queue. Enforce the byte
/// limit even for compressed or chunked responses whose decoded size isn't known up front.
final class ArtworkTransfer: APIRedirectPolicy, @unchecked Sendable {
  typealias Body = (Data, HTTPURLResponse)

  private final class Pending {
    let limit: Int
    let completion: CheckedContinuation<Body, Error>
    var response: HTTPURLResponse?
    var data = Data()
    init(limit: Int, completion: CheckedContinuation<Body, Error>) {
      self.limit = limit
      self.completion = completion
    }
  }

  // Registration and every access below run on the same session's serial delegate queue.
  private var pending: [Int: Pending] = [:]

  func read(_ request: URLRequest, from session: URLSession, limit: Int) async throws -> Body {
    try Task.checkCancellation()
    let task = session.dataTask(with: request)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        session.delegateQueue.addOperation {
          guard task.state == .suspended else {
            continuation.resume(throwing: CancellationError())
            return
          }
          self.pending[task.taskIdentifier] = Pending(limit: limit, completion: continuation)
          task.resume()
        }
      }
    } onCancel: { task.cancel() }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
    didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
    let id = dataTask.taskIdentifier
    guard let item = pending[id], let http = response as? HTTPURLResponse, http.statusCode == 200,
      response.expectedContentLength <= item.limit else {
      pending.removeValue(forKey: id)?.completion.resume(throwing: URLError(.badServerResponse))
      completionHandler(.cancel)
      return
    }
    item.response = http
    if response.expectedContentLength > 0 { item.data.reserveCapacity(Int(response.expectedContentLength)) }
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    let id = dataTask.taskIdentifier
    guard let item = pending[id] else { return }
    guard data.count <= item.limit - item.data.count else {
      pending.removeValue(forKey: id)
      dataTask.cancel()
      item.completion.resume(throwing: URLError(.dataLengthExceedsMaximum))
      return
    }
    item.data.append(data)
  }

  override func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    super.urlSession(session, task: task, didCompleteWithError: error)
    guard let item = pending.removeValue(forKey: task.taskIdentifier) else { return }
    if let error { item.completion.resume(throwing: error) }
    else if let response = item.response { item.completion.resume(returning: (item.data, response)) }
    else { item.completion.resume(throwing: URLError(.badServerResponse)) }
  }
}
