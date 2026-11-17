import CLiveRemux
import Foundation

struct ClockPCM: Sendable {
  let bytes: Data, rate: Int, channels: Int, frames: Int, startSample: Int64, layout: [Int32],
    videoStart: Double?
  var duration: Double { Double(frames) / Double(rate) }
  static func decode(
    initial: Data, media: Data, offset: Int64, target: ByteSpan, filter: String = "volume=volume=1"
  ) async throws -> Self {
    guard initial.count <= 4 * 1024 * 1024, media.count <= 48 * 1024 * 1024 else {
      throw DecoderProblem.size
    }
    let t = Task.detached(priority: .userInitiated) { () throws -> Self in
      try Task.checkCancellation()
      var info = PLTimingPCM()
      var out: UnsafeMutablePointer<UInt8>?
      var size: Int32 = 0
      var err = [CChar](repeating: 0, count: 96)
      let status = initial.withUnsafeBytes { i in
        media.withUnsafeBytes { m in
          filter.withCString { f in
            pl_audio_pcm(
              i.bindMemory(to: UInt8.self).baseAddress, Int32(i.count),
              m.bindMemory(to: UInt8.self).baseAddress, Int32(m.count), offset, target.lower,
              target.upper, f, nil, { _ in Task.isCancelled ? 1 : 0 }, &info, &out, &size, &err, 96)
          }
        }
      }
      guard status == 0, let out, size > 0, (1...8).contains(info.channels), info.frames > 0,
        Int(size) == Int(info.frames) * Int(info.channels) * 4
      else {
        if let out { pl_free_audio(out) }
        try Task.checkCancellation()
        throw DecoderProblem.unsupported
      }
      let data = Data(
        bytesNoCopy: out, count: Int(size), deallocator: .custom { p, _ in pl_free_audio(p) })
      let ids = withUnsafeBytes(of: &info.layout) {
        Array($0.bindMemory(to: Int32.self).prefix(Int(info.channels)))
      }
      return .init(
        bytes: data, rate: Int(info.rate), channels: Int(info.channels), frames: Int(info.frames),
        startSample: info.first_sample, layout: ids,
        videoStart: info.first_video_seconds.isFinite ? info.first_video_seconds : nil)
    }
    return try await withTaskCancellationHandler {
      try await t.value
    } onCancel: {
      t.cancel()
    }
  }
}
struct ClockAudioPart: Sendable {
  let index: Int, start: Double, pcm: ClockPCM
}
protocol PictureTimingSource: AnyObject, Sendable {
  var clockFPS: Double? { get }
  func clockIndex(at time: Double) -> Int?
  func clockPart(_ index: Int) async throws -> ClockAudioPart?
  func nextClockIndex(after index: Int) async throws -> Int?
}
extension PictureTimingSource {
  func nextClockIndex(after index: Int) async throws -> Int? { index < Int.max ? index + 1 : nil }
}
protocol DatedPictureTimingSource: PictureTimingSource {
  func locate(itemTime: Double, date: Date?)
}
final class PictureTimingRegistry: @unchecked Sendable {
  static let shared = PictureTimingRegistry()
  private final class Weak {
    weak var source: (any PictureTimingSource)?
    init(_ source: any PictureTimingSource) { self.source = source }
  }
  private var sources: [URL: Weak] = [:]
  private let lock = NSLock()
  private init() {}
  func add(_ url: URL, source: any PictureTimingSource) {
    lock.withLock {
      sources = sources.filter { $0.value.source != nil }
      sources[url] = Weak(source)
    }
  }
  func source(_ url: URL) -> (any PictureTimingSource)? { lock.withLock { sources[url]?.source } }
}
