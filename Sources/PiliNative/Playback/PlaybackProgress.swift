import Combine
import Foundation
import SwiftUI

/// Progress has its own publisher so ticking controls/captions do not invalidate detail lists.
@MainActor final class PlaybackProgress: ObservableObject {
  @Published private(set) var seconds = 0.0
  private var publishedAt = -Double.infinity

  func update(_ value: Double, immediate: Bool = false, host: Double = ProcessInfo.processInfo.systemUptime) {
    guard value.isFinite, value != seconds else { return }
    guard immediate || host - publishedAt >= 0.25 else { return }
    publishedAt = host
    seconds = value
  }
}

/// A data-flow boundary only; the caller owns all layout and appearance.
struct PlaybackProgressContent<Content: View>: View {
  @ObservedObject var progress: PlaybackProgress
  @ViewBuilder let content: () -> Content
  var body: some View { content() }
}

struct PlaybackCaption: View {
  let model: PlayerModel
  var fullscreen = false, interactive = true
  var body: some View {
    if !model.cues.isEmpty {
      PlaybackProgressContent(progress: model.progress) {
        if let text = model.cues.active(at: model.seconds) {
          CaptionLine(text: text, fullscreen: fullscreen, interactive: interactive)
        }
      }
    }
  }
}
