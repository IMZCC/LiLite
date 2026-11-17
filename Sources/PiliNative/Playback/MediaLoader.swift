import AVFoundation
import UniformTypeIdentifiers

/// AVFoundation requests are served in bounded ranges. Cancelling a seek cancels its outstanding
/// range; a new item/line owns a fresh cache, so bytes cannot cross encodings or accounts.
final class MediaLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
  private let url: URL, reference: URL, audioOnly: Bool
  private let authorize:(@Sendable() async throws -> Void)?
  private let queue = DispatchQueue(label: "pilinative.media")
  private let transport = RangeTransport(), buffer = MediaBufferSession()
  private var active: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var total: Int64?, contentType: String?, stopped = false
  init(url: URL, reference: URL, audioOnly: Bool = false,authorize:(@Sendable() async throws -> Void)?=nil) {
    self.authorize=authorize
    self.url = url
    self.reference = reference
    self.audioOnly = audioOnly
  }
  func makeItem() -> AVPlayerItem {
    let asset = AVURLAsset(
      url: URL(
        string: audioOnly ? "pili-stream://media/audio.m4a" : "pili-stream://media/video.mp4")!)
    asset.resourceLoader.setDelegate(self, queue: queue)
    return AVPlayerItem(asset: asset)
  }
  func stop() {
    transport.close()
    buffer.close()
    queue.async {
      self.stopped = true
      self.active.values.forEach { $0.cancel() }
      self.active.removeAll()
      self.total = nil
      self.contentType = nil
    }
  }
  private func request(_ from: Int64, _ to: Int64) -> URLRequest {
    var r = URLRequest(url: url)
    r.httpShouldHandleCookies = false
    r.setValue(reference.absoluteString, forHTTPHeaderField: "Referer")
    r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    r.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
    r.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
      forHTTPHeaderField: "User-Agent")
    return r
  }
  private func onQueue<T>(_ f: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      queue.async { continuation.resume(with: Result(catching: f)) }
    }
  }
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader,
    shouldWaitForLoadingOfRequestedResource r: AVAssetResourceLoadingRequest
  ) -> Bool {
    let key = ObjectIdentifier(r)
    guard !stopped else {
      r.finishLoading(with: URLError(.cancelled))
      return true
    }
    let known = total
    let type = contentType
    active[key] = Task {
      do {
        try await authorize?()
        let length: Int64
        let uti: String
        if let known, let type {
          length = known
          uti = type
        } else {
          let first = try await transport.response(
            request(0, 1), limit: 2, acceptsShortResource: true)
          length = first.total
          uti =
            audioOnly
            ? (first.mimeType.flatMap { UTType(mimeType: $0) }.flatMap {
              $0.conforms(to: .audio) ? $0.identifier : nil
            } ?? UTType.mpeg4Audio.identifier) : UTType.mpeg4Movie.identifier
        }
        try Task.checkCancellation();try await authorize?()
        let desired: Range<Int64>? = try await onQueue {
          guard !self.stopped, self.active[key] != nil, !r.isCancelled else {
            throw CancellationError()
          }
          guard length > 0, length < Int64.max, self.total.map({ $0 == length }) ?? true else {
            throw URLError(.badServerResponse)
          }
          self.total = length
          self.contentType = uti
          if let info = r.contentInformationRequest {
            info.contentType = uti
            info.contentLength = length
            info.isByteRangeAccessSupported = true
          }
          guard let d = r.dataRequest else { return nil }
          let start = max(d.currentOffset, d.requestedOffset)
          let (requestedEnd, overflow) = d.requestedOffset.addingReportingOverflow(
            Int64(d.requestedLength))
          guard start >= 0, start <= length,
            d.requestsAllDataToEndOfResource || (!overflow && requestedEnd >= start)
          else { throw URLError(.badServerResponse) }
          return start..<(d.requestsAllDataToEndOfResource ? length : min(requestedEnd, length))
        }
        if let desired {
          var next = desired.lowerBound
          while next < desired.upperBound {
            try Task.checkCancellation()
            let through = next + min(desired.upperBound - next, 256 * 1024) - 1
            try await authorize?()
            let bytes = try await buffer.window.read(
              lane: 0, from: next, through: through, endOfMedia: length - 1
            ) { a, b in
              try await self.authorize?()
              let got = try await self.transport.response(self.request(a, b), limit: Int(b - a + 1))
              guard got.total == length else { throw URLError(.badServerResponse) }
              return got.data
            }
            try await authorize?()
            try await onQueue {
              guard !self.stopped, self.active[key] != nil, !r.isCancelled, let d = r.dataRequest
              else { throw CancellationError() }
              d.respond(with: bytes)
            }
            next = through + 1
          }
        }
        try Task.checkCancellation()
        queue.async {
          guard self.active.removeValue(forKey: key) != nil, !r.isCancelled else { return }
          r.finishLoading()
        }
      } catch {
        queue.async {
          guard self.active.removeValue(forKey: key) != nil, !r.isCancelled else { return }
          r.finishLoading(with: error)
        }
      }
    }
    return true
  }
  func resourceLoader(
    _ resourceLoader: AVAssetResourceLoader, didCancel r: AVAssetResourceLoadingRequest
  ) {
    active.removeValue(forKey: ObjectIdentifier(r))?.cancel()
  }
}
