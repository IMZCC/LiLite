import Foundation

enum BulletVoteReceipt: Equatable {
  case applied(Bool)
  case already(Bool)
  var liked: Bool {
    switch self {
    case .applied(let on), .already(let on): on
    }
  }
  static func reconcile(_ code: Int, requested: Bool) throws -> Self {
    switch code {
    case 0: .applied(requested)
    case 65006: .already(true)
    case 65004: .already(false)
    default: throw ServiceError("点赞未成功", code: code)
    }
  }
  func count(_ previous: Int, wasLiked: Bool) -> Int {
    guard case .applied(let on) = self, on != wasLiked else { return previous }
    return on ? (previous == Int.max ? previous : previous + 1) : max(0, previous - 1)
  }
}
enum BulletComplaintReceipt {
  static func verify(_ raw: Data) throws {
    struct Reply: Decodable {
      struct Result: Decodable { let block: Int? }
      let code: Int, data: Result?
    }
    let r = try JSONDecoder().decode(Reply.self, from: raw)
    guard r.code == 0 else { throw ServiceError("举报未提交", code: r.code) }
    if let status = r.data?.block, status < 0 {
      throw ServiceError(
        [
          -1: "请先激活账号", -2: "服务未受理这次举报", -3: "账号已被禁言", -4: "操作过于频繁", -5: "你已举报过这条弹幕",
          -6: "举报服务暂不可用",
        ][status] ?? "举报未提交", code: status)
    }
  }
}
