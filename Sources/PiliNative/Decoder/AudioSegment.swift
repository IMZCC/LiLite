import CLiveRemux
import Foundation

private struct AudioRenditionError: LocalizedError {
  var errorDescription: String? { "此音轨无法应用当前声音效果" }
}
enum AudioSegment {
  static func supports(_ codec: String) -> Bool {
    let c = codec.lowercased()
    return [
      "mp4a.40.1", "mp4a.40.2", "mp4a.40.3", "mp4a.40.4", "mp4a.40.5", "mp4a.40.17", "mp4a.40.23",
      "mp4a.40.29", "mp4a.69", "mp4a.6b", "alac", "flac", "opus",
    ].contains(c)
  }
  static func convert(
    initial: Data, media: Data, offset: Int64, target: ByteSpan, index: Int, filter: String
  ) async throws -> DecoderFragment {
    guard initial.count <= 4 * 1024 * 1024, media.count <= 48 * 1024 * 1024, !filter.isEmpty else {
      throw DecoderProblem.size
    }
    let worker = Task.detached(priority: .userInitiated) { () throws -> DecoderFragment in
      try Task.checkCancellation()
      var out: UnsafeMutablePointer<UInt8>?
      var size: Int32 = 0
      var err = [CChar](repeating: 0, count: 128)
      let value = initial.withUnsafeBytes { i in
        media.withUnsafeBytes { m in
          filter.withCString { f in
            pl_audio_segment(
              i.bindMemory(to: UInt8.self).baseAddress, Int32(i.count),
              m.bindMemory(to: UInt8.self).baseAddress, Int32(m.count), offset, target.lower,
              target.upper, f, nil, { _ in Task.isCancelled ? 1 : 0 }, &out, &size, &err, 128)
          }
        }
      }
      guard value == 0, let out, size > 0 else {
        if let out { pl_free_audio(out) }
        try Task.checkCancellation()
        throw AudioRenditionError()
      }
      let data = Data(
        bytesNoCopy: out, count: Int(size), deallocator: .custom { p, _ in pl_free_audio(p) })
      try Task.checkCancellation()
      return try DecoderFragment(data, index: index, audio: true)
    }
    return try await withTaskCancellationHandler {
      try await worker.value
    } onCancel: {
      worker.cancel()
    }
  }
}
