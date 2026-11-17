import Foundation

struct DashStream: Decodable {
  private var chosenAddress:URL?=nil
  let id: Int, codecs: String, bandwidth: Int
  let width: Int?, height: Int?, frameRate: Double?
  let baseUrl: String, backupUrl: [String]?, SegmentBase: Ranges
  struct Ranges: Decodable {
    let Initialization: String, indexRange: String
    init(initial: String, index: String) {
      Initialization = initial
      indexRange = index
    }
    enum Keys: String, CodingKey { case Initialization, initialization, indexRange, index_range }
    init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      Initialization =
        try c.decodeIfPresent(String.self, forKey: .Initialization)
        ?? c.decode(String.self, forKey: .initialization)
      indexRange =
        try c.decodeIfPresent(String.self, forKey: .indexRange)
        ?? c.decode(String.self, forKey: .index_range)
    }
  }
  enum Keys: String, CodingKey {
    case width, height, frameRate, frame_rate, id, codecs, bandwidth, baseUrl, base_url, backupUrl,
      backup_url, SegmentBase, segment_base
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    id = try c.decode(Int.self, forKey: .id)
    codecs = try c.decode(String.self, forKey: .codecs)
    bandwidth = try c.decode(Int.self, forKey: .bandwidth)
    width = try? c.decode(Int.self, forKey: .width)
    height = try? c.decode(Int.self, forKey: .height)
    func fps(_ key: Keys) -> Double? {
      if let n = try? c.decode(Double.self, forKey: key) { return n }
      guard let raw = try? c.decode(String.self, forKey: key) else { return nil }
      let terms = raw.split(separator: "/", omittingEmptySubsequences: false)
      if terms.count == 2, let num = Double(terms[0]), let den = Double(terms[1]), den > 0 {
        return num / den
      }
      return terms.count == 1 ? Double(raw) : nil
    }
    frameRate = [fps(.frameRate), fps(.frame_rate)].compactMap { $0 }.first {
      $0.isFinite && $0 > 0 && $0 <= 480
    }
    baseUrl =
      try c.decodeIfPresent(String.self, forKey: .baseUrl)
      ?? c.decode(String.self, forKey: .base_url)
    backupUrl =
      try c.decodeIfPresent([String].self, forKey: .backupUrl)
      ?? c.decodeIfPresent([String].self, forKey: .backup_url)
    SegmentBase =
      try c.decodeIfPresent(Ranges.self, forKey: .SegmentBase)
      ?? c.decode(Ranges.self, forKey: .segment_base)
  }
  /// Non-network rendition rebuilt from an already-open, authorized offline file.
  init(localID: Int, codec: String, rate: Int, width: Int?, height: Int?, initial: String) {
    id = localID
    codecs = codec
    bandwidth = rate
    self.width = width
    self.height = height
    frameRate = nil
    baseUrl = ""
    backupUrl = nil
    SegmentBase = Ranges(initial: initial, index: "")
  }
  func masterAttributes(audio: DashStream?, audioCodec: String? = nil, audioRate: Int? = nil)
    -> String
  {
    let sum = max(0, bandwidth).addingReportingOverflow(max(0, audioRate ?? audio?.bandwidth ?? 0))
    var parts = ["BANDWIDTH=" + String(sum.overflow ? Int.max : max(1, sum.partialValue))]
    let codecs = [self.codecs, audioCodec ?? audio?.codecs].compactMap { $0 }
    if codecs.allSatisfy({
      !$0.isEmpty
        && $0.utf8.allSatisfy { b in
          (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b) || b == 45
            || b == 46
        }
    }) {
      parts.append("CODECS=\"" + codecs.joined(separator: ",") + "\"")
    }
    if let width, let height, (1...32768).contains(width), (1...32768).contains(height) {
      parts.append("RESOLUTION=" + String(width) + "x" + String(height))
    }
    if let frameRate {
      parts.append(
        "FRAME-RATE=" + String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), frameRate)
      )
    }
    if audio != nil { parts.append("AUDIO=\"audio\"") }
    return parts.joined(separator: ",")
  }
  func selecting(_ url:URL?) throws ->Self{
    guard let url else{return self}
    guard originals.contains(url) else{throw ServiceError("所选地址不属于这条音视频轨道")}
    var stream=self;stream.chosenAddress=url;return stream
  }
  func routes(audio: Bool) -> [URL] { chosenAddress.map{[$0]} ?? VODLine.current(originals, audio: audio) }
  var originals: [URL] { ([baseUrl] + (backupUrl ?? [])).compactMap(httpsURL) }
}
struct SpokenTrack: Decodable, Identifiable, Equatable {
  let lang: String?, title: String?, subtitle_lang: String?, production_type: Int?
  var id: String { lang ?? "" }
  var label: String { (title ?? lang ?? "原声") + (production_type == 2 ? "（AI）" : "") }
}
struct SpokenCatalog: Decodable {
  let support: Bool?, items: [SpokenTrack]?
  var ordered: [SpokenTrack] {
    guard support != false else { return [] }
    var seen = Set<String>()
    return (items ?? []).filter { !$0.id.isEmpty && seen.insert($0.id).inserted }.enumerated()
      .sorted { a, b in
        func rank(_ x: SpokenTrack) -> Int {
          (x.id.lowercased().contains("zh") ? 0 : 2) + (x.production_type == 2 ? 1 : 0)
        }
        let l = rank(a.element)
        let r = rank(b.element)
        return l == r ? a.offset < b.offset : l < r
      }.map(\.element)
  }
}
struct DashFormats: Decodable {
  var isPreview=false
  var spoken: [SpokenTrack] = []
  var selectedLanguage: String? = nil
  var volume: AudioMeasurements? = nil
  func withLanguages(
    _ catalog: SpokenCatalog?, _ selection: String?, volume: AudioMeasurements? = nil
  ) -> Self {
    var copy = self
    copy.spoken = catalog?.ordered ?? []
    copy.selectedLanguage = selection
    copy.volume = volume
    return copy
  }
  func filteringVideo(_ predicate: (Int) -> Bool) -> Self {
    var copy = self
    copy.video = video.filter { predicate($0.id) }
    return copy
  }
  func missingBelowHighest(_ advertised: [Int]) -> Int? {
    guard let highest = video.first?.id else { return nil }
    let present = Set(video.map(\.id))
    return advertised.filter { $0 < highest && !present.contains($0) }.max()
  }
  func mergingVideo(_ extra: DashFormats) -> Self {
    var copy = self
    func key(_ item: DashStream) -> String {
      let codec = item.codecs.lowercased()
      let family = codec.hasPrefix("avc") ? "avc" : (codec.hasPrefix("hvc") || codec.hasPrefix("hev") || codec.hasPrefix("dvh") || codec.hasPrefix("dvhe")) ? "hevc" : String(codec.split(separator: ".").first ?? "")
      return String(item.id) + ":" + family
    }
    var seen = Set(video.map(key))
    for item in extra.video where seen.insert(key(item)).inserted { copy.video.append(item) }
    copy.video.sort { $0.id > $1.id }
    return copy
  }
  private(set) var video: [DashStream]
  let audio: [DashStream]?
  let advertisedAudio: Bool
  private struct Stream: Decodable {
    let value: DashStream?
    init(from d: Decoder) throws { value = try? DashStream(from: d) }
  }
  private struct Dolby: Decodable { let audio: [Stream]? }
  private struct Flac: Decodable { let audio: Stream? }
  enum Keys: String, CodingKey { case video, audio, dolby, flac }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    video = try c.decode([Stream].self, forKey: .video).compactMap(\.value)
    let base = try c.decodeIfPresent([Stream].self, forKey: .audio) ?? []
    let lossless = try c.decodeIfPresent(Flac.self, forKey: .flac)?.audio
    let surround = try c.decodeIfPresent(Dolby.self, forKey: .dolby)?.audio ?? []
    advertisedAudio = !base.isEmpty || lossless != nil || !surround.isEmpty
    audio = (base + [lossless].compactMap { $0 } + surround).compactMap(\.value)
  }
}
