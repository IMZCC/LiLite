import Foundation

struct EpisodeClip: Codable, Hashable, Identifiable {
  let clipType: String
  let start, end: Double
  var id: String { "\(clipType):\(start):\(end)" }
  var title: String { clipType == "CLIP_TYPE_OP" ? "片头" : "片尾" }
  var usable: Bool {
    ["CLIP_TYPE_OP", "CLIP_TYPE_ED"].contains(clipType) && start.isFinite && end.isFinite
      && start >= 0 && end > start
  }
  func contains(_ seconds: Double) -> Bool { usable && start <= seconds && seconds < end }
}
enum EpisodeSkipMode: String, CaseIterable {
  case once, always, manual, show, off
  var title: String {
    switch self {
    case .once: return "跳过一次"
    case .always: return "总是跳过"
    case .manual: return "手动跳过"
    case .show: return "仅显示"
    case .off: return "关闭"
    }
  }
}
struct EpisodeSkipHistory {
  private var skipped = Set<String>()
  mutating func target(_ clip: EpisodeClip?, mode: EpisodeSkipMode) -> Double? {
    guard let clip, clip.usable else { return nil }
    switch mode {
    case .always: return clip.end
    case .once: return skipped.insert(clip.id).inserted ? clip.end : nil
    default: return nil
    }
  }
}
