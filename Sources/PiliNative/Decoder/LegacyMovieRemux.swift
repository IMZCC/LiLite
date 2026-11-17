import CLiveRemux
import Foundation

enum LegacyMovieRemux {
  private final class Interrupt: @unchecked Sendable {
    let stopped: @Sendable () -> Bool
    init(_ stopped: @escaping @Sendable () -> Bool) { self.stopped = stopped }
  }
  static func convert(_ input: URL, to output: URL, beginning: Double? = nil,
    cancelled: @escaping @Sendable () -> Bool = { false }) async throws {
    let task = Task.detached(priority: .userInitiated) {
      try Task.checkCancellation()
      let interrupt = Interrupt(cancelled)
      let context = Unmanaged.passUnretained(interrupt).toOpaque()
      var message = [CChar](repeating: 0, count: 128)
      let status = withExtendedLifetime(interrupt) {
        input.path.withCString { source in
          output.path.withCString { destination in
            let stop: PLInterrupted = { context in
              guard let context else { return 1 }
              return Task.isCancelled || Unmanaged<Interrupt>.fromOpaque(context).takeUnretainedValue().stopped() ? 1 : 0
            }
            if let beginning { return pl_vod_remux_window(source, destination, beginning, context, stop, &message, 128) }
            return pl_vod_remux_file(source, destination, context, stop, &message, 128)
          }
        }
      }
      try Task.checkCancellation()
      if cancelled() { throw CancellationError() }
      guard status == 0 else { throw ServiceError("无法读取此视频的旧式媒体流") }
    }
    do {
      try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    } catch { try? FileManager.default.removeItem(at: output); throw error }
  }
}
