import Foundation

struct NetworkMediaRules: Codable, Equatable {
  static let key = "play.networkMedia"
  static let videoIDs = [0, 6, 16, 32, 64, 74, 80, 100, 112, 116, 120, 125, 126, 127, 129]
  static let audioIDs = [0, 30216, 30232, 30280, 30250, 30255, 30251]
  static let liveIDs = [80, 150, 250, 400, 10000, 15000, 20000, 25000, 30000]
  static let families = ["AVC", "HEVC", "AV1", "DVH1"]
  var wifiVideo = 127, cellVideo = 80, wifiAudio = 30251, cellAudio = 30280
  var wifiLive = 10000, cellLive = 250
  var wifiCodecs = ["AVC", "AV1"], cellCodecs: [String]? = nil
  func validate() throws {
    guard [wifiVideo, cellVideo].allSatisfy(Self.videoIDs.contains),
      [wifiAudio, cellAudio].allSatisfy(Self.audioIDs.contains),
      [wifiLive, cellLive].allSatisfy(Self.liveIDs.contains),
      [wifiCodecs, cellCodecs ?? wifiCodecs].allSatisfy({ a in
        !a.isEmpty && Set(a).count == a.count && a.allSatisfy(Self.families.contains)
      })
    else { throw ServiceError("网络播放偏好无效") }
  }
  static func legacy(video: Int?, audio: Int?, codec: String?) -> Self {
    var r = Self()
    if let video { r.wifiVideo = video }
    if let audio { r.wifiAudio = audio }
    if let codec, let f = family(codec) { r.wifiCodecs = [f] }
    return r
  }
  static func current(_ d: UserDefaults = .standard) -> Self {
    if let data = d.data(forKey: key), let r = try? JSONDecoder().decode(Self.self, from: data),
      (try? r.validate()) != nil
    {
      return r
    }
    return legacy(
      video: d.object(forKey: "play.quality") as? Int,
      audio: d.object(forKey: "play.audioQuality") as? Int, codec: d.string(forKey: "play.codec"))
  }
  func save(_ d: UserDefaults = .standard) throws {
    try validate()
    d.set(try JSONEncoder().encode(self), forKey: Self.key)
  }
  static func family(_ codec: String) -> String? {
    let p = codec.lowercased()
    if p.hasPrefix("avc1") || p.hasPrefix("avc3") { return "AVC" }
    if p.hasPrefix("hev1") || p.hasPrefix("hvc1") { return "HEVC" }
    if p.hasPrefix("av01") { return "AV1" }
    if p.hasPrefix("dvh1") || p.hasPrefix("dvhe") { return "DVH1" }
    return nil
  }
  static func audioRank(_ id: Int) -> Int {
    [30251: 60, 30255: 50, 30250: 50, 30280: 40, 30232: 30, 30216: 20][id] ?? 0
  }
  static func target<T>(_ items: [T], target: Int, score: (T) -> Int) -> T? {
    let sorted = items.sorted { score($0) > score($1) }
    return target == 0 ? sorted.first : sorted.first(where: { score($0) <= target }) ?? sorted.last
  }
  func codecOrder(cellular: Bool) -> [String] { cellular ? (cellCodecs ?? wifiCodecs) : wifiCodecs }
}
// The download panel uses the general (non-cellular) preferences on every network.
enum OfflineQuality {
  static func video(_ offered: [Int], rules: NetworkMediaRules = .current()) -> Int? {
    NetworkMediaRules.target(offered, target: rules.wifiVideo, score: { $0 })
  }
  static func audio(_ offered: [Int], rules: NetworkMediaRules = .current()) -> Int? {
    if offered.contains(rules.wifiAudio) { return rules.wifiAudio }
    return NetworkMediaRules.target(offered, target: NetworkMediaRules.audioRank(rules.wifiAudio),
      score: NetworkMediaRules.audioRank)
  }
}
