import Foundation

struct LiveDirectoryPage {
  struct Tag: Decodable, Hashable { let name: String?, sort_type: String? }
  let page: Page<LiveRoom>
  var followed: [LiveRoom] = [], areas: [LiveFeedCards.Tab] = [], tags: [Tag] = []
}
extension BiliAPI {
  private static let liveHost = "api.live.bilibili.com"
  private func liveActionResult(_ request: URLRequest, identity: Identity, use: AccountUse) async throws {
    struct Ack: Decodable { let code: Int, message: String?, msg: String? }
    let (bytes, response) = try await webResponse(request, identity: identity, use: use)
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError("服务器未接受请求") }
    let ack = try JSONDecoder().decode(Ack.self, from: bytes)
    guard ack.code == 0 else { throw ServiceError(ack.message ?? ack.msg ?? "操作未成功") }
  }
  func mobileLiveRooms(page: Int, owner: String?, area: Int?, child: String?, sort: String?)
    async throws -> LiveDirectoryPage
  {
    let user = try await AccountJar.shared.current(.role(.recommend),credentials:.mobile)
    guard user?.id == owner else { throw ServiceError("推荐账号已切换") }
    var query = [
      "mobi_app": "iphone", "platform": "ios", "device": "phone", "https_url_req": "1",
      "s_locale": "zh_CN", "c_locale": "zh_CN", "page": String(page),
    ]
    if let token = user?.mobileToken, !token.isEmpty {
      query["access_key"] = token
      query["relation_page"] = "1"
    }
    func stamp(_ rooms: [LiveRoom]) -> [LiveRoom] {
      rooms.map { item in
        var row = item
        row.page = page
        row.viewer = owner
        return row
      }
    }
    if let area {
      struct List: Decodable {
        let list: [LiveRoom]?, count: Int?, new_tags: [LiveDirectoryPage.Tag]?
      }
      query["parent_area_id"] = String(area)
      query["area_id"] = child ?? "0"
      query["page_size"] = "20"
      query["sort_type"] = sort
      query["tag_version"] = "1"
      let r = try await read(
        "/xlive/app-interface/v2/second/getList", query, host: Self.liveHost,
        expectedAccount: owner ?? "", as: List.self)
      let rows = stamp(r.list ?? [])
      let more = !rows.isEmpty && (r.count.map { page * 20 < $0 } ?? (rows.count == 20))
      return .init(
        page: .init(items: rows, next: more ? String(page + 1) : nil), tags: r.new_tags ?? [])
    }
    let data = try await read(
      "/xlive/app-interface/v2/index/feed", query, host: Self.liveHost,
      expectedAccount: owner ?? "", as: LiveFeedCards.self)
    return .init(
      page: .init(
        items: stamp(data.card_list.compactMap(\.room)),
        next: data.has_more == 1 ? String(page + 1) : nil),
      followed: data.card_list.flatMap(\.followed), areas: data.card_list.flatMap(\.areas))
  }
  func liveFeedback(_ room: LiveRoom, reason: LiveFeedbackGroup.Reason, owner: String) async throws
  {
    guard var fields = room.feedbackFields(reason, owner: owner),
      let user = try await AccountJar.shared.current(.role(.recommend),credentials:.both), user.id == owner
    else {
      throw ServiceError("推荐账号或直播卡片已变更")
    }
    guard let token = user.mobileToken, !token.isEmpty else { throw ServiceError("请先为推荐账号完成移动端授权") }
    fields["access_key"] = token
    fields["mobi_app"] = "iphone"
    fields["platform"] = "ios"
    var c = URLComponents()
    c.scheme = "https"
    c.host = Self.liveHost
    c.path = "/xlive/app-interface/v2/index/feedback"
    c.queryItems = fields.sorted { $0.key < $1.key }.map(URLQueryItem.init)
    guard let url = c.url else { throw URLError(.badURL) }
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 18)
    req.setValue(user.header, forHTTPHeaderField: "Cookie")
    // This endpoint mutates state despite its GET method. Do not use read retries.
    try await liveActionResult(req, identity: user, use: .role(.recommend))
  }
  func likeLive(room: LiveRoomIdentity, taps: Int, owner: String) async throws {
    guard room.room_id > 0, room.uid > 0, taps > 0,
      let user = try await AccountJar.shared.current(.role(.heartbeat)),
      user.id == owner, let csrf = user.csrf,
      let unsigned = room.likeFields(taps: taps, owner: owner, csrf: csrf)
    else { throw ServiceError("观看账号已切换或未登录") }
    let fields = try await sign(unsigned)
    try Task.checkCancellation()
    guard try await AccountJar.shared.current(.role(.heartbeat))?.id == owner else {
      throw ServiceError("观看账号已切换")
    }
    var req = URLRequest(
      url: URL(
        string: "https://api.live.bilibili.com/xlive/app-ucenter/v1/like_info_v3/like/likeReportV3")!,
      timeoutInterval: 18)
    req.httpMethod = "POST"
    req.setValue(
      "application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
    req.setValue("https://live.bilibili.com/\(room.room_id)", forHTTPHeaderField: "Referer")
    req.setValue(user.header, forHTTPHeaderField: "Cookie")
    let allowed = CharacterSet(
      charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    req.httpBody = Data(
      fields.sorted { $0.key < $1.key }.map {
        $0.key + "=" + ($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
      }.joined(separator: "&").utf8)
    try await liveActionResult(req, identity: user, use: .role(.heartbeat))
  }
  func changeLiveShield(room: Int64, sender: Int64, adding: Bool, owner: String) async throws {
    guard room > 0, sender > 0, !owner.isEmpty else { throw ServiceError("无法识别发送者") }
    try await submit(
      "/liveact/shield_user",
      [
        "uid": String(sender), "roomid": String(room),
        "type": adding ? "1" : "0",
      ], expectedAccount: owner, service: .live)
  }
}
