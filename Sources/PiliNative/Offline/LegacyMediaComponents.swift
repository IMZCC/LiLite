import Foundation

enum LegacyMediaComponents {
  static func component(_ n: Int) -> String { String(format: "part-%04d", n) }
  static func isPart(_ value: String) -> Bool {
    guard value.count == 9, value.hasPrefix("part-"), let n = Int(value.suffix(4)),
      (0..<256).contains(n), component(n) == value else { return false }
    return true
  }
  static func ordered(_ components: [String]) -> Bool {
    !components.isEmpty && components.count <= 256 && components.enumerated().allSatisfy { $0.element == component($0.offset) }
  }
}
