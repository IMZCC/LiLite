import Foundation

struct TimelineSource: Hashable {
  let bvid: String?, aid: Int64?, cid: Int64
}
struct ShotMap: Decodable {
  let columns: Int, rows: Int, width: Int, height: Int, images: [String], times: [Int]
  enum CodingKeys: String, CodingKey {
    case columns = "img_x_len"
    case rows = "img_y_len"
    case width = "img_x_size"
    case height = "img_y_size"
    case images = "image"
    case times = "index"
  }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    columns = try c.decode(Int.self, forKey: .columns)
    rows = try c.decode(Int.self, forKey: .rows)
    width = try c.decode(Int.self, forKey: .width)
    height = try c.decode(Int.self, forKey: .height)
    images = try c.decode([String].self, forKey: .images)
    times = try c.decode([Int].self, forKey: .times)
    guard (1...128).contains(columns), (1...128).contains(rows), (1...2048).contains(width),
      (1...2048).contains(height), !images.isEmpty, images.count <= 4096, !times.isEmpty,
      times.count <= 1_000_000,
      (times.first ?? -1) >= 0, zip(times, times.dropFirst()).allSatisfy({ $0.0 <= $0.1 })
    else { throw ServiceError("视频预览索引无效") }
  }
  struct Tile: Equatable { let image: String, x: Int, y: Int, width: Int, height: Int }
  func tile(_ seconds: Double) -> Tile? {
    guard seconds.isFinite else { return nil }
    var lo = 0
    var hi = times.count
    while lo < hi {
      let mid = lo + (hi - lo) / 2
      if Double(times[mid]) <= seconds { lo = mid + 1 } else { hi = mid }
    }
    // Upstream's timestamps start with a leading zero before the first frame boundary.
    let slot = max(0, lo - 2)
    let sheet = slot / (columns * rows)
    guard images.indices.contains(sheet) else { return nil }
    let within = slot % (columns * rows)
    return Tile(
      image: images[sheet], x: (within % columns) * width, y: (within / columns) * height,
      width: width, height: height)
  }
}
struct ActivityTrend: Decodable {
  struct Events: Decodable {
    let values: [Double]
    enum CodingKeys: String, CodingKey { case values = "default" }
  }
  let step: Double, events: Events
  enum CodingKeys: String, CodingKey {
    case step = "step_sec"
    case events
  }
  static func parse(_ bytes: Data) throws -> Self {
    struct Module: Decodable {
      struct Params: Decodable { let data: ActivityTrend }
      let params: Params
    }
    struct Wrapper: Decodable {
      let first: Module
      enum Keys: String, CodingKey { case modules }
      init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        var a = try c.nestedUnkeyedContainer(forKey: .modules)
        first = try a.decode(Module.self)
      }
    }
    guard bytes.count <= 2 * 1024 * 1024 else { throw ServiceError("高能进度数据过大") }
    let dec = JSONDecoder()
    let t: Self
    if let first = (try? dec.decode(Wrapper.self, from: bytes))?.first {
      t = first.params.data
    } else {
      t = try dec.decode(Self.self, from: bytes)
    }
    guard t.step.isFinite, t.step > 0, !t.events.values.isEmpty, t.events.values.count <= 200_000,
      t.events.values.allSatisfy({ $0.isFinite && $0 >= 0 })
    else { throw ServiceError("高能进度数据无效") }
    return t
  }
  func peaks(columns: Int, duration: Double) -> [Double] {
    guard columns > 0, duration > 0, duration.isFinite else { return [] }
    let n = min(columns, 2048)
    var bins = [Double](repeating: 0, count: n)
    for (i, value) in events.values.enumerated() {
      let t = Double(i) * step
      guard t <= duration else { break }
      let bin = min(n - 1, Int(t / duration * Double(n)))
      bins[bin] = max(bins[bin], value)
    }
    guard let top = bins.max(), top > 0 else { return [] }
    return bins.map { $0 / top }
  }
}
