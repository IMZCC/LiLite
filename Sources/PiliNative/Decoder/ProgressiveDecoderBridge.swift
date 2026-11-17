import Foundation

final class ProgressiveMediaRanges: @unchecked Sendable {
  private let transport = RangeTransport(), url: URL, reference: URL
  init(url: URL, reference: URL) throws {
    guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil,
      url.password == nil,
      reference.scheme?.lowercased() == "https", reference.host != nil
    else { throw URLError(.unsupportedURL) }
    self.url = url
    self.reference = reference
  }
  func read(_ a: Int64, _ n: Int) async throws -> (data: Data, total: Int64) {
    guard a >= 0, n > 0, n <= 512 * 1024, a <= Int64.max - Int64(n) else {
      throw LocalIndexIssue.invalid
    }
    var req = URLRequest(url: url)
    req.httpShouldHandleCookies = false
    req.setValue(reference.absoluteString, forHTTPHeaderField: "Referer")
    req.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
    req.setValue("bytes=\(a)-\(a+Int64(n)-1)", forHTTPHeaderField: "Range")
    req.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
      forHTTPHeaderField: "User-Agent")
    let b = try await transport.response(req, limit: n)
    return (b.data, b.total)
  }
  deinit { transport.close() }
  func close() { transport.close() }
}

enum ProgressiveDecoderBridge {
  static func open(
    url: URL, reference: URL, quality: Int, owner: String, volume: AudioMeasurements? = nil,
    routes: [NativeVideoRoute]? = nil, audioOnly: Bool = false
  ) async throws -> (bridge: DashBridge, url: URL) {
    let remote = try ProgressiveMediaRanges(url: url, reference: reference)
    func authorize() async throws {
      try Task.checkCancellation()
      guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == owner else {
        throw ServiceError("视频账号已切换")
      }
    }
    try await authorize()
    let meta = try await RemoteMovieMetadata.open { a, n in try await remote.read(a, n) }
    try await authorize()
    let task = Task.detached(priority: .userInitiated) { try LocalMovieFragments.open(meta) }
    let (v, a) = try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
    let source = OfflineDecoderSource(
      video: v, audio: a, quality: quality, owner: owner, remote: remote, volume: volume)
    return try await start(source, routes: routes, audioOnly: audioOnly)
  }
  /// Independent user-entered media never receive a service referrer, cookies or an account token.
  static func independent(_ video:URL,audio:URL?,owner:String)async throws->(bridge:DashBridge,url:URL){
    func source(_ u:URL)throws->ProgressiveMediaRanges{
      guard let host=u.host else{throw URLError(.badURL)}
      var ref=URLComponents();ref.scheme="https";ref.host=host;ref.path="/"
      guard let home=ref.url else{throw URLError(.badURL)};return try .init(url:u,reference:home)
    }
    let v=try source(video)
    if audio==nil{
      let meta=try await RemoteMovieMetadata.open{a,n in try await v.read(a,n)}
      let task=Task.detached(priority:.userInitiated){try LocalMovieFragments.open(meta)}
      let (vi,ai)=try await withTaskCancellationHandler{try await task.value}onCancel:{task.cancel()}
      try Task.checkCancellation()
      return try await start(.init(video:vi,audio:ai,quality:0,owner:owner,remote:v),routes:nil)
    }
    guard let audio else{throw LocalIndexIssue.invalid}
    let a=try source(audio)
    async let vm=RemoteMovieMetadata.open{x,n in try await v.read(x,n)}
    async let am=RemoteMovieMetadata.open{x,n in try await a.read(x,n)}
    let (videoMeta,audioMeta)=try await (vm,am)
    let task=Task.detached(priority:.userInitiated){try (LocalMovieFragments.track(videoMeta,audio:false),LocalMovieFragments.track(audioMeta,audio:true))}
    let (vi,ai)=try await withTaskCancellationHandler{try await task.value}onCancel:{task.cancel()}
    try Task.checkCancellation()
    return try await start(.init(video:vi,audio:ai,quality:0,owner:owner,remote:v,remoteAudio:a),routes:nil)
  }
  static func start(_ source: OfflineDecoderSource, routes: [NativeVideoRoute]?, audioOnly: Bool = false) async throws -> (
    bridge: DashBridge, url: URL
  ) {
    let b = DashBridge(local: source, decoding: routes)
    do {
      if audioOnly {
        guard let audio = source.audioStream else { throw ServiceError("此视频没有可用的音轨") }
        return try await (b, b.startAudio(audio, volume: source.volume))
      }
      return try await (b, b.startLocal())
    } catch {
      b.close()
      throw error
    }
  }
}
