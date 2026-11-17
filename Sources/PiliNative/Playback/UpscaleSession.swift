import SwiftUI

enum UpscaleMode: Int, CaseIterable, Identifiable {
  case off, efficiency, quality
  var id: Self { self }
  var label: String {
    switch self {
    case .off: return "关闭"
    case .efficiency: return "效率"
    case .quality: return "画质"
    }
  }
  var preset: String { self == .quality ? "quality" : "efficiency" }
}
@MainActor final class UpscaleSession: ObservableObject {
  static let key = "player.upscale"
  @Published private(set) var mode: UpscaleMode = .off
  @Published private(set) var note: String?
  @Published private(set) var activation = 0
  @Published private(set) var nativeRange = false
  func dynamicRange(_ quality: Int) {
    let hdr = [125, 126, 129].contains(quality)
    if nativeRange != hdr {
      nativeRange = hdr
      note = nil
    }
  }
  private var source: String?, animation = false
  func begin(id: String, anime: Bool) {
    guard source != id || animation != anime else { return }
    source = id
    animation = anime
    note = nil
    mode =
      anime
      ? (UpscaleMode(rawValue: UserDefaults.standard.integer(forKey: Self.key)) ?? .off) : .off
  }
  func choose(_ value: UpscaleMode) {
    activation &+= 1
    note = nil
    mode = value
    if animation && !UserDefaults.standard.bool(forKey: "play.temporaryPreferences") {
      UserDefaults.standard.set(value.rawValue, forKey: Self.key)
    }
  }
  func status(_ text: String?) { if note != text { note = text } }
}

struct UpscaleButton: View {
  @ObservedObject var session: UpscaleSession
  var body: some View {
    Menu {
      Picker("Anime4K 超分辨率", selection: Binding(get: { session.mode }, set: session.choose)) {
        ForEach(UpscaleMode.allCases) { Text($0.label).tag($0) }
      }
      if session.nativeRange && session.mode != .off {
        Text("HDR 视频使用原画")
      } else if let note = session.note {
        Text(note)
      }
    } label: {
      PlayerGlyph(symbol: session.mode == .off ? "sparkles.tv" : "sparkles.tv.fill", dimmed: session.mode == .off)
    }
    .accessibilityLabel("Anime4K 超分辨率").accessibilityValue(session.mode.label)
  }
}
