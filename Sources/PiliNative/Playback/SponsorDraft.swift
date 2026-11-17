import Foundation

struct SponsorDraft: Identifiable, Hashable {
  let id = UUID()
  var start = 0.0
  var end: Double
  init(end: Double) { self.end = end }
  var category = "sponsor", action = "skip"
  var kind: SponsorCategory {
    SponsorCategory.all.first { $0.id == category } ?? SponsorCategory.all[0]
  }
  mutating func select(_ value: String) {
    category = value
    if !kind.actions.contains(action) { action = kind.actions[0] }
  }
  func range(duration: Double) throws -> [Double] {
    guard duration.isFinite, duration > 0,
      SponsorCategory.all.contains(where: { $0.id == category && $0.actions.contains(action) })
    else { throw ServiceError("请选择有效的片段类别和操作") }
    if action == "full" { return [0, 0] }
    guard start.isFinite, start >= 0, start <= duration else { throw ServiceError("开始时间超出视频范围") }
    if action == "poi" { return [start, start] }
    guard end.isFinite, end <= duration, end > start else {
      throw ServiceError("结束时间须晚于开始时间，且不能超过视频时长")
    }
    return [start, end]
  }
  static func payload(_ rows: [Self], duration: Double) throws -> [[String: Any]] {
    guard !rows.isEmpty else { throw ServiceError("请先添加片段") }
    return try rows.enumerated().map { i, row in
      do {
        return [
          "segment": try row.range(duration: duration), "category": row.category,
          "actionType": row.action,
        ]
      } catch { throw ServiceError("第 \(i+1) 段：" + error.localizedDescription) }
    }
  }
}
