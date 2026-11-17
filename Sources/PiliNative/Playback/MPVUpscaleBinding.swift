import SwiftUI

/// The mpv backend uses the original Flutter shader chains; AVPlayer keeps its Metal renderer.
struct MPVUpscaleBinding: View {
  let player: MPVPlayer
  @ObservedObject var session: UpscaleSession
  private var key: String { "\(session.mode.rawValue)-\(session.nativeRange)-\(session.activation)" }
  var body: some View {
    Color.clear.frame(width: 0, height: 0).task(id: key) {
      do {
        if session.mode == .off || session.nativeRange {
          try await player.core.command(["change-list", "glsl-shaders", "clr", ""])
          return
        }
        let names = session.mode == .quality ? [
          "Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_VL", "Anime4K_Upscale_CNN_x2_VL",
          "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4", "Anime4K_Upscale_CNN_x2_M",
        ] : [
          "Anime4K_Clamp_Highlights", "Anime4K_Restore_CNN_M", "Anime4K_Restore_CNN_S",
          "Anime4K_Upscale_CNN_x2_M", "Anime4K_AutoDownscalePre_x2", "Anime4K_AutoDownscalePre_x4",
          "Anime4K_Upscale_CNN_x2_S",
        ]
        let paths = try names.map { name -> String in
          guard let url = Bundle.module.url(forResource: name, withExtension: "glsl", subdirectory: "UpscaleAssets/MPVShaders") else {
            throw ServiceError("找不到超分辨率资源")
          }
          return url.path
        }
        try await player.core.command(["change-list", "glsl-shaders", "set", paths.joined(separator: ":")])
        session.status(nil)
      } catch { if !Task.isCancelled { session.status(error.localizedDescription) } }
    }
  }
}
