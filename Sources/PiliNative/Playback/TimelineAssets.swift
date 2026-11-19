import Foundation
import ImageIO
import SwiftUI

extension BiliAPI {
  func videoShots(_ source: TimelineSource) async throws -> ShotMap {
    var q = ["cid": String(source.cid), "index": "1"]
    if let b = source.bvid { q["bvid"] = b } else if let a = source.aid { q["aid"] = String(a) }
    return try await read("/x/player/videoshot", q, as: ShotMap.self)
  }
}

private final class TimelineHTTP: @unchecked Sendable {
  static let shared = TimelineHTTP()
  let session: URLSession
  init() {
    let c = URLSessionConfiguration.ephemeral
    c.httpCookieStorage = nil
    c.httpShouldSetCookies = false
    c.urlCredentialStorage = nil
    c.urlCache = nil
    session = URLSession(configuration: c, delegate: APIRedirectPolicy(), delegateQueue: nil)
  }
  func fetch(_ url: URL, ref: String, limit: Int) async throws -> Data {
    var r = URLRequest(url: url, timeoutInterval: 10)
    r.httpShouldHandleCookies = false
    r.setValue(ref, forHTTPHeaderField: "Referer")
    r.setValue("https://www.bilibili.com", forHTTPHeaderField: "Origin")
    let (stream, resp) = try await session.bytes(for: r)
    guard (resp as? HTTPURLResponse)?.statusCode == 200, resp.expectedContentLength <= limit else {
      throw ServiceError("未能取得视频预览")
    }
    var result = Data()
    for try await b in stream {
      guard result.count < limit else { throw ServiceError("视频预览过大") }
      result.append(b)
    }
    return result
  }
}
extension TimelineSource {
  fileprivate var reference: String {
    "https://www.bilibili.com/video/" + (bvid ?? aid.map { "av" + String($0) } ?? "") + "/"
  }
}
@MainActor final class TimelineState: ObservableObject {
  @Published private(set) var source: TimelineSource?
  @Published var showChapterMarks=true
  @Published private(set) var chapterStarts: [Double] = []
  private var preparedChapters: (String, Int64, [Double])?
  func updateChapters(_ values: [VideoPositions.Chapter], bvid: String, cid: Int64) {
    let points = Set(values.map(\.from).filter { $0 > 0 }).sorted().prefix(4096).map(Double.init)
    preparedChapters = (bvid, cid, points)
    if source?.bvid == bvid && source?.cid == cid { chapterStarts = points }
  }
  @Published private(set) var shots: ShotMap?
  @Published var showTrendOverlay=true
  private(set) var trendRevision=0
  @Published private(set) var trend:ActivityTrend?{didSet{trendRevision &+= 1}}
  private var thumbs: Task<Void, Never>?, activity: Task<Void, Never>?
  private var lastShots = Date.distantPast, lastTrend = Date.distantPast
  func reset(_ target: TimelineSource?) {
    thumbs?.cancel()
    activity?.cancel()
    thumbs = nil
    activity = nil
    source = target
    if let target, let (bvid, cid, points) = preparedChapters, target.bvid == bvid,
      target.cid == cid
    {
      chapterStarts = points
    } else {
      chapterStarts = []
    }
    shots = nil
    trend = nil
    lastShots = .distantPast
    lastTrend = .distantPast
  }
  func requestShots() {
    guard let source, thumbs == nil, shots == nil, Date().timeIntervalSince(lastShots) > 5 else {
      return
    }
    lastShots = Date()
    thumbs = Task {
      let result = try? await BiliAPI.shared.videoShots(source)
      guard !Task.isCancelled, self.source == source else { return }
      shots = result
      thumbs = nil
    }
  }
  func requestTrend() {
    guard let source, activity == nil, trend == nil, Date().timeIntervalSince(lastTrend) > 5 else {
      return
    }
    lastTrend = Date()
    activity = Task {
      var url = URLComponents()
      url.scheme = "https"
      url.host = "bvc.bilivideo.com"
      url.path = "/pbp/data"
      var q = ["cid": String(source.cid), "r": "loader"]
      q["aid"] = source.aid.map(String.init)
      q["bvid"] = source.bvid
      url.queryItems = q.sorted { $0.key < $1.key }.map(URLQueryItem.init)
      var values: ActivityTrend?
      if let u = url.url,
        let bytes = try? await TimelineHTTP.shared.fetch(
          u, ref: source.reference, limit: 2 * 1024 * 1024)
      {
        let parsing = Task.detached(priority: .utility) {
          try Task.checkCancellation()
          return try ActivityTrend.parse(bytes)
        }
        values = try? await withTaskCancellationHandler { try await parsing.value } onCancel: { parsing.cancel() }
      }
      guard !Task.isCancelled, self.source == source else { return }
      trend = values
      activity = nil
    }
  }
}
private actor ShotImages {
  static let shared = ShotImages()
  private let cache = NSCache<NSURL, CGImage>()
  private init() { cache.totalCostLimit = 48 * 1024 * 1024 }
  func sheet(_ raw: String, ref: String) async -> CGImage? {
    guard let u = httpsURL(raw), let host = u.host?.lowercased(),
      ["hdslb.com", "biliimg.com", "bilivideo.com"].contains(where: {
        host == $0 || host.hasSuffix("." + $0)
      })
    else { return nil }
    if let hit = cache.object(forKey: u as NSURL) { return hit }
    guard let b = try? await TimelineHTTP.shared.fetch(u, ref: ref, limit: 8 * 1024 * 1024),
      !Task.isCancelled,
      let imageSource = CGImageSourceCreateWithData(b as CFData, nil),
      let info = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any],
      let w = info[kCGImagePropertyPixelWidth] as? Int,
      let h = info[kCGImagePropertyPixelHeight] as? Int,
      w > 0, h > 0, w <= 32768, h <= 32768, w <= 16_000_000 / h,
      let image = CGImageSourceCreateImageAtIndex(
        imageSource, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { return nil }
    cache.setObject(image, forKey: u as NSURL, cost: w * h * 4)
    return image
  }
}
struct ShotPreview: View {
  @ObservedObject var state: TimelineState
  let seconds: Double
  /// The largest the frame is drawn; the fullscreen scrub preview is bigger than the inline one.
  var limit = CGSize(width: 160, height: 90)
  var corner: CGFloat = 8
  var framed = false
  @State private var sheet: CGImage?
  @State private var loaded: String?
  var body: some View {
    let tile = state.shots?.tile(seconds)
    ZStack {
      Color.clear.frame(width: 0, height: 0)
      if let t = tile, loaded == t.image, let sheet, t.x + t.width <= sheet.width,
        t.y + t.height <= sheet.height,
        let cut = sheet.cropping(to: CGRect(x: t.x, y: t.y, width: t.width, height: t.height))
      {
        Image(decorative: cut, scale: 1).resizable().aspectRatio(contentMode: .fit).frame(
          maxWidth: limit.width, maxHeight: limit.height
        ).clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
          if framed {
            RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(.white, lineWidth: 2)
          }
        }
      }
    }.task(id: state.source) { state.requestShots() }.task(id: tile?.image) {
      loaded = nil
      sheet = nil
      guard let tile, let source = state.source else { return }
      let image = await ShotImages.shared.sheet(tile.image, ref: source.reference)
      if !Task.isCancelled {
        sheet = image
        loaded = tile.image
      }
    }.allowsHitTesting(false).accessibilityHidden(true)
  }
}
struct TimelineSlider: View {
  @ObservedObject var model: PlayerModel
  @ObservedObject private var progress: PlaybackProgress
  @ObservedObject var state: TimelineState
  @AppStorage("player.seekPreview") private var preview = true
  @AppStorage("player.trend") private var chart = false
  @State private var seeking: Double?
  init(model: PlayerModel) {
    self.model = model
    self.progress = model.progress
    self.state = model.timeline
  }
  var body: some View {
    VStack(spacing: 2) {
      if preview, let seeking { ShotPreview(state: state, seconds: seeking) }
      if let text = model.sponsorToast {
        Text(text).piliFont(.caption).foregroundStyle(.secondary).modifier(ToastAlpha())
      }
      if let s = model.sponsor.first(where: {
        model.sponsorRules.mode($0) == 2 && $0.segment[0] <= model.seconds
          && model.seconds < $0.segment[1]
      }) {
        Button("跳过" + (s.detail?.title ?? "片段")) { model.skipSponsor(s) }.buttonStyle(.borderless)
      }
      if !model.sponsor.isEmpty {
        SponsorMarkers(rows: model.sponsor, duration: model.duration, rules: model.sponsorRules)
      }
      if chart,state.showTrendOverlay{ArchiveTrendStrip(timeline:state,duration:model.duration).frame(height:18)}
      HStack {
        Text(clockText(seeking ?? model.seconds)).font(.caption.monospacedDigit())
        Slider(
          value: Binding(
            get: { min(seeking ?? model.seconds, max(1, model.duration)) }, set: { seeking = $0 }),
          in: 0...max(1, model.duration)
        ) { editing in
          if !editing, let t = seeking {
            model.seek(t)
            seeking = nil
          }
        }.accessibilityLabel("播放进度").disabled(model.duration <= 0)
        Text(clockText(model.duration)).font(.caption.monospacedDigit())
      }
    }.task(id: state.source) { if chart { state.requestTrend() } }
      .onChange(of: chart) { _, on in if on { state.requestTrend() } }
  }
}
