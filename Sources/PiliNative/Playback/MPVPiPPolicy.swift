import Foundation

/// Shared sizing and closing rules; independent of UIKit for host-side checks.
enum MPVPiPPolicy {
  static func bufferSize(source: CGSize, render: CGSize) -> CGSize {
    guard source.width.isFinite, source.height.isFinite, source.width > 0, source.height > 0 else { return .zero }
    var scale = min(1, 1920 / max(source.width, source.height))
    if render.width.isFinite, render.height.isFinite, render.width > 0, render.height > 0 {
      scale = min(scale, max(render.width / source.width, render.height / source.height))
    }
    return CGSize(width: max(1, (source.width * scale).rounded()), height: max(1, (source.height * scale).rounded()))
  }
  static func pauseOnClose(restoring: Bool, requested: Bool, background: Bool, continuePlaying: Bool) -> Bool {
    !restoring && !requested && background && !continuePlaying
  }
}
