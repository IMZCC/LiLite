import Foundation

struct CaptureTiming {
  enum Decision: Equatable { case skip, capture, complete }
  let seconds: Double, fps: Int
  private(set) var samples: [Double] = []
  mutating func next(_ time: Double) throws -> Decision {
    guard time.isFinite, seconds.isFinite, seconds > 0, fps > 0 else {
      throw ServiceError("录制时间无效")
    }
    guard let first = samples.first, let last = samples.last else {
      samples.append(time)
      return .capture
    }
    if time < last - 0.05 || time - last > 1.5 { throw ServiceError("播放进度已改变，请重新录制") }
    let progress = time - first
    if progress >= seconds || samples.count >= Int(ceil(seconds * Double(fps))) { return .complete }
    if time - last < 0.85 / Double(fps) || progress + 0.004 < Double(samples.count) / Double(fps) {
      return .skip
    }
    samples.append(time)
    return .capture
  }
  func delays() -> [Double] {
    guard let first = samples.first else { return [] }
    return samples.indices.map { i in
      let end =
        i + 1 < samples.count ? samples[i + 1] : min(samples[i] + 1 / Double(fps), first + seconds)
      return max(0.02, end - samples[i])
    }
  }
}
