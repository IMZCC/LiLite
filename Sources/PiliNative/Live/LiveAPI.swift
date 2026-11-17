import Foundation

extension BiliAPI {
  func liveSubareas(parent: Int, owner: String?) async throws -> [LiveAreaTag] {
    let role = try await AccountJar.shared.current(.role(.recommend),credentials:.mobile)
    guard role?.id == owner else { throw ServiceError("账号已切换") }
    var fields = ["parent_id": String(parent), "need_entrance": "1", "source_id": "2", "platform": "ios", "mobi_app": "iphone"]
    fields["access_key"] = role?.mobileToken
    return try await read("/room/v1/Area/getList", fields, host: "api.live.bilibili.com", expectedAccount: owner ?? "", as: [LiveAreaTag].self)
  }
  func rooms(area: Int?, child: String?, page: Int) async throws -> Page<LiveRoom> {
    struct List: Decodable { let list: [LiveRoom]? }
    var p = ["page": "\(page)", "page_size": "20", "platform": "web"]
    if let area {
      p["parent_area_id"] = "\(area)"
      p["area_id"] = child ?? "0"
      p["sort_type"] = "online"
    }
    let r = try await read(
      area == nil
        ? "/xlive/web-interface/v1/second/getUserRecommend"
        : "/xlive/web-interface/v1/second/getList", try await sign(p),
      host: "api.live.bilibili.com", as: List.self)
    return Page(items: r.list ?? [], next: (r.list?.count ?? 0) >= 20 ? "\(page+1)" : nil)
  }
  func liveStream(_ id: Int64, quality: Int, audioOnly: Bool, owner: String) async throws -> LiveSource {
    let params = LiveSource.request(room:id,quality:quality,audioOnly:audioOnly)
    return try await read("/xlive/web-room/v2/index/getRoomPlayInfo", try await sign(params),
      host:"api.live.bilibili.com", expectedAccount:owner, as:LiveSource.self)
  }
  func recentChat(_ id: Int64, reader: String?) async throws -> [LiveLine] {
    let data = try await fetch(
      "/xlive/web-room/v1/dM/gethistory", ["roomid": String(id)],
      host: "api.live.bilibili.com", expectedAccount: reader ?? "")
    return try LiveMessageSource.history(data, room: id)
  }
  struct ChatConfig: Decodable {
    struct Endpoint: Decodable { let host: String, wss_port: Int }
    let token: String
    let host_list: [Endpoint]
  }
  func chatConfig(_ id: Int64, reader:String?) async throws -> ChatConfig {
    try await read(
      "/xlive/web-room/v1/index/getDanmuInfo", try await sign(["id": "\(id)", "type": "0"]),
      host: "api.live.bilibili.com", expectedAccount:reader ?? "", as: ChatConfig.self)
  }
}
