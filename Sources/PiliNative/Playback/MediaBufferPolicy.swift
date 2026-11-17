import Foundation

enum MediaBufferPolicy {
  static let vodKey = "play.bufferMB", liveKey = "live.bufferMB", mib = 1024 * 1024
  static let maxSetting = 512.0
  static func capacity(live: Bool, vod: Double, override: Double, physical: UInt64) -> Int {
    let v = vod.isFinite && vod >= 0 ? min(maxSetting, vod) : 4
    let mb = live ? (override.isFinite && override > 0 ? min(override, maxSetting) : v * 2) : v
    // Per direction; reserve headroom for the decoder, UIKit and simultaneous A/V requests.
    let ceiling = Int(min(UInt64(128 * mib), max(UInt64(8 * mib), physical / 48)))
    return min(ceiling, Int((mb * Double(mib)).rounded()))
  }
  static func current(live: Bool, defaults: UserDefaults = .standard) -> Int {
    capacity(
      live: live, vod: defaults.object(forKey: vodKey) as? Double ?? 4,
      override: defaults.object(forKey: liveKey) as? Double ?? 0,
      physical: ProcessInfo.processInfo.physicalMemory)
  }
  static func horizon(after last: Int64, end: Int64?, bitsPerSecond: Int, seconds: Double) -> Int64?
  {
    guard let end, end >= last, last >= 0, bitsPerSecond > 0, seconds.isFinite, seconds >= 0 else {
      return end
    }
    // Clamp before conversion; subtraction saturates even for huge remote bitrate values.
    let possible = Double(bitsPerSecond) * min(seconds, 3600) / 8
    let allowance = Int64(min(Double(128 * mib), possible).rounded(.up))
    return last + min(end - last, allowance)
  }
  static func liveSeconds(capacity: Int, bitsPerSecond: Double, limit: Double) -> Double? {
    guard bitsPerSecond.isFinite && bitsPerSecond > 0 else { return nil }
    let seconds = max(0.05, Double(capacity) * 8 / bitsPerSecond)
    return min(limit.isFinite && limit > 0 ? limit : .greatestFiniteMagnitude, seconds)
  }
}

final class MediaBufferPressure: @unchecked Sendable {
  #if canImport(Darwin)
    private let source: DispatchSourceMemoryPressure
  #endif
  init(_ release: @escaping @Sendable () -> Void) {
    #if canImport(Darwin)
      source = DispatchSource.makeMemoryPressureSource(
        eventMask: [.warning, .critical], queue: .global(qos: .utility))
      source.setEventHandler(handler: release)
      source.resume()
    #endif
  }
  deinit {
    #if canImport(Darwin)
      source.cancel()
    #endif
  }
}
