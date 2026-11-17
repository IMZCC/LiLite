import Foundation

extension BiliAPI {
  func liveAreaSections(owner: String?) async throws -> [LiveAreaSection] {
    struct Result: Decodable { let list: [LiveAreaSection]? }
    let role = try await AccountJar.shared.current(.role(.recommend),credentials:.mobile)
    guard role?.id == owner else { throw ServiceError("账号已切换") }
    var fields = ["platform": "ios", "mobi_app": "iphone"]
    fields["access_key"] = role?.mobileToken
    return try await read("/xlive/app-interface/v2/index/getAreaList", fields, host: "api.live.bilibili.com",
      expectedAccount: owner ?? "", as: Result.self).list ?? []
  }

  private func liveTagParameters(_ owner: String) async throws -> [String: String] {
    guard let actor = try await AccountJar.shared.current(credentials:.mobile), actor.id == owner else { throw ServiceError("账号已切换") }
    var fields = ["platform": "ios", "mobi_app": "iphone"]
    fields["access_key"] = actor.mobileToken
    return fields
  }

  func liveFavoriteTags(_ owner: String) async throws -> [LiveAreaTag] {
    struct Result: Decodable { let tags: [LiveAreaTag]? }
    let fields = try await liveTagParameters(owner)
    let data = try await read("/xlive/app-interface/v2/second/get_fav_tag", fields, host: "api.live.bilibili.com",
      expectedAccount: owner, as: Result.self)
    return data.tags ?? []
  }

  func saveLiveTags(_ order: [Int], replacing baseline: [Int], owner: String) async throws {
    guard order.allSatisfy({ $0 > 0 }), Set(order).count == order.count else { throw ServiceError("直播分区无效") }
    let current = try await liveFavoriteTags(owner).map(\.area)
    if current == order { return }
    guard current == baseline else { throw ServiceError("常用标签已在其他设备更改，请重新载入") }
    var fields = try await liveTagParameters(owner)
    fields["tags"] = order.map(String.init).joined(separator: ",")
    try await submit("/xlive/app-interface/v2/second/set_fav_tag", fields, expectedAccount: owner, service: .live)
  }
}
