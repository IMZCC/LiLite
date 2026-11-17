import Foundation
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

enum LegacyOfflineMedia {
  static func isFLV(_ file: URL) throws -> Bool {
    let source = try FileHandle(forReadingFrom: file)
    defer { try? source.close() }
    return try source.read(upToCount: 3)?.starts(with: [0x46, 0x4c, 0x56]) == true
  }
  /// Finished downloads are only published after their real sample tables and tracks open.
  /// FLV is converted locally without decoding; a cancelled conversion keeps its complete source.
  static func prepare(_ file: URL) async throws {
    if try isFLV(file) {
      let temporary = file.deletingLastPathComponent().appendingPathComponent("legacy-prepared-" + UUID().uuidString + ".mp4")
      defer { try? FileManager.default.removeItem(at: temporary) }
      try await LegacyMovieRemux.convert(file, to: temporary)
      try await validate(temporary)
      try Task.checkCancellation()
      let result = temporary.path.withCString { from in file.path.withCString { to in rename(from, to) } }
      guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    } else { try await validate(file) }
  }
  static func validate(_ file: URL) async throws {
    let task = Task.detached(priority: .userInitiated) {
      let (v, a) = try LocalMovieFragments.open(LocalMediaFile(file))
      guard !v.fragments.isEmpty, v.fragments.allSatisfy({ $0.seconds.isFinite && $0.seconds > 0 }),
        a.map({ !$0.fragments.isEmpty && $0.fragments.allSatisfy { $0.seconds.isFinite && $0.seconds > 0 } }) ?? true
      else { throw ServiceError("下载的视频片段不完整") }
    }
    try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
  }
}
