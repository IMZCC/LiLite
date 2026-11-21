import CoreText
import Metal
import SwiftUI

/// One-time costs the first screens would otherwise pay on the main thread, paid in the
/// background shortly after launch instead.
enum LaunchWarmup {
  /// Symbols drawn on the main columns and video cards; each one's vector glyph is parsed
  /// synchronously the first time it is drawn.
  private static let symbols = [
    "play.rectangle", "list.bullet.rectangle", "ellipsis", "bell", "magnifyingglass",
    "clock.arrow.circlepath", "text.badge.plus", "star.fill", "arrow.down.circle.fill",
    "hand.thumbsup", "hand.thumbsup.fill", "hand.thumbsdown", "bubble.left", "text.bubble",
    "arrowshape.turn.up.right", "chevron.right", "chevron.down", "person.crop.circle.fill",
    "heart", "heart.fill", "square.and.pencil", "arrow.clockwise", "play.fill", "pause.fill",
    "arrow.left", "headphones", "airplayvideo", "pip.enter", "list.bullet",
    "arrow.up.left.and.arrow.down.right", "checkmark.circle.fill", "eye.slash.fill",
    // 我的: shortcuts and the library / social / account rows.
    "doc.text.fill", "graduationcap.fill", "play.rectangle.fill", "rectangle.stack.fill",
    "bubble.left.and.bubble.right.fill", "text.bubble.fill", "person.2.fill", "iphone.gen3", "key.fill",
    "hand.raised.fill", "bitcoinsign.circle.fill", "chart.line.uptrend.xyaxis", "location.fill",
    "gearshape.fill", "person.crop.circle.badge.xmark", "circle.circle", "folder.badge.plus",
    // A card's long-press menu: its items are made, glyphs and all, as the finger goes down on
    // the card, so a cold glyph there delays the tap that opens the video (~45 ms measured).
    "doc.on.doc", "person.crop.circle", "text.quote", "person.slash", "photo",
    "square.and.arrow.down", "clock",
  ]
  /// Point sizes the symbols are drawn at (rows, shortcuts, cards).
  private static let symbolSizes: [(CGFloat, UIImage.SymbolWeight)] = [(16, .semibold), (19, .semibold), (17, .medium), (13, .regular)]
  @MainActor static func start() {
    let scale = UIScreen.main.scale
    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1.5) {
      // SwiftUI's renderer creates the GPU device the first time a view needs it (a Canvas,
      // shader or blur), on the main thread: 120-160 ms measured. The device is shared, so
      // making it here leaves that call nothing to do.
      _ = MTLCreateSystemDefaultDevice()
      // Drawn, not only loaded: a symbol's glyph is rasterized the first time it is drawn.
      let format = UIGraphicsImageRendererFormat()
      format.scale = scale
      for (size, weight) in symbolSizes {
        let config = UIImage.SymbolConfiguration(pointSize: size, weight: weight)
        let images = symbols.compactMap { UIImage(systemName: $0, withConfiguration: config) }
        _ = UIGraphicsImageRenderer(size: CGSize(width: size * 2, height: size * 2), format: format).image { _ in
          for image in images { image.draw(at: .zero) }
        }
      }
      // Titles mix Chinese, kana, Hangul and emoji; each script's fallback font is loaded the
      // first time a line needs it. Lay one line of each weight out here first.
      for style in [UIFont.TextStyle.body, .subheadline, .caption1] {
        for weight in [UIFont.Weight.regular, .semibold] {
          let size = UIFont.preferredFont(forTextStyle: style).pointSize
          let text = NSAttributedString(
            string: "中文標題 かなカナ 한글 ABC 123 😀🎉",
            attributes: [.font: UIFont.systemFont(ofSize: size, weight: weight)])
          let line = CTLineCreateWithAttributedString(text)
          _ = CTLineGetTypographicBounds(line, nil, nil, nil)
          _ = CTLineGetGlyphRuns(line)
        }
      }
    }
  }
}

/// Starts loading a video's details while its card is still under the finger: the push and the
/// page's first frame take long enough that the page then opens with its details in hand
/// instead of a second round of layout when they arrive.
@MainActor final class ArchiveDetailPrefetch {
  static let shared = ArchiveDetailPrefetch()
  private struct Entry {
    let started: Date
    let task: Task<Video, Error>
  }
  private var entries: [String: Entry] = [:]
  /// How long a prefetched answer stands in for a fresh request.
  private let lifetime: TimeInterval = 20

  func warm(_ bvid: String) {
    guard !bvid.isEmpty else { return }
    prune()
    if entries[bvid] != nil { return }
    entries[bvid] = Entry(started: Date(), task: Task { try await BiliAPI.shared.detail(bvid) })
  }
  /// The prefetched details when they are fresh (and succeeded), otherwise a new request.
  func detail(_ bvid: String) async throws -> Video {
    prune()
    if let entry = entries.removeValue(forKey: bvid), let video = try? await entry.task.value {
      return video
    }
    return try await BiliAPI.shared.detail(bvid)
  }
  private func prune() {
    let now = Date()
    entries = entries.filter { now.timeIntervalSince($0.value.started) < lifetime }
  }
}

/// `.plain` with a hook when the press begins, for prefetching what the button opens. It adds
/// no gesture of its own, so cards do not get any more expensive to hit-test.
struct PressPrefetchStyle: ButtonStyle {
  let pressed: @MainActor () -> Void
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .opacity(configuration.isPressed ? 0.75 : 1)
      .onChange(of: configuration.isPressed) { _, down in if down { pressed() } }
  }
}
