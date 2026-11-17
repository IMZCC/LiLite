import Foundation
import LocalAuthentication

enum PackAuthorization {
  static func verify(_ reason: String) async throws {
    let context = LAContext()
    context.localizedCancelTitle = "取消"
    defer { context.invalidate() }
    var issue: NSError?
    guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &issue) else {
      throw ServiceError("请先为设备设置解锁密码，再导入或导出登录账号")
    }
    guard try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
    else {
      throw ServiceError("未通过身份验证")
    }
  }
}
