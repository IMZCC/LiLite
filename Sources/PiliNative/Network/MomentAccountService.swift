import Foundation

extension BiliAPI {
  /// The public detail normally follows the viewing/history identity. Editing, first-party status and receipt checks belong to the main account.
  func mainDynamicRow(_ id: String, owner: String) async throws -> [String: Any] {
    guard let n = Int64(id), n > 0, !owner.isEmpty else { throw ServiceError("动态编号无效") }
    var c = URLComponents(string: "https://api.bilibili.com/x/polymer/web-dynamic/v1/detail")!
    c.queryItems = [
      .init(name: "id", value: id), .init(name: "features", value: "itemOpusStyle"),
      .init(name: "web_location", value: "333.1330"), .init(name: "timezone_offset", value: "-480"),
    ]
    guard let url = c.url else { throw URLError(.badURL) }
    return try await ConnectionRetry.current().perform(readOnly: true) { _ in
      guard let u = try await AccountJar.shared.current(.role(.main)), u.id == owner else {
        throw ServiceError("账号已切换")
      }
      var req = URLRequest(url: url, timeoutInterval: 18)
      req.httpShouldHandleCookies = false
      req.setValue(u.header, forHTTPHeaderField: "Cookie")
      req.setValue("https://t.bilibili.com/", forHTTPHeaderField: "Referer")
      let (bytes, http) = try await self.webResponse(req, identity: u)
      let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
      guard (http as? HTTPURLResponse)?.statusCode == 200, value?["code"] as? Int == 0,
        let row = (value?["data"] as? [String: Any])?["item"] as? [String: Any],
        row["id_str"] as? String == id
      else { throw ServiceError(value?["message"] as? String ?? "未能读取动态") }
      guard try await AccountJar.shared.current(.role(.main))?.id == owner else {
        throw ServiceError("账号已切换")
      }
      return row
    }
  }
  func viewerReservation(dynamic: String, rid: Int64, owner: String) async throws
    -> MomentReservation
  {
    let row = try await mainDynamicRow(dynamic, owner: owner)
    guard let module = (row["modules"] as? [String: Any])?["module_dynamic"] as? [String: Any],
      let r = MomentResources(module).reserve, r.id == rid
    else { throw ServiceError("预约卡片已更新") }
    return r
  }
}
