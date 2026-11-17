import Foundation

extension BiliAPI {
  func recordLiveVisit(room: Int64, owner: String) async throws {
    func enabled() -> Bool { UserDefaults.standard.object(forKey: "history.sync") as? Bool != false }
    guard room > 0, enabled() else { return }
    let paused = try await read("/x/v2/history/shadow", ["jsonp":"jsonp"], expectedAccount: owner, as: Bool.self)
    try Task.checkCancellation()
    guard !paused, enabled(), let actor = try await AccountJar.shared.current(.role(.heartbeat)),
      actor.id == owner, let csrf = actor.csrf, !csrf.isEmpty else { return }
    let path = "/xlive/web-room/v1/index/roomEntryAction"
    var url = URLComponents()
    url.scheme = "https"; url.host = "api.live.bilibili.com"; url.path = path
    url.queryItems = [URLQueryItem(name: "csrf", value: csrf)]
    guard let target = url.url else { throw URLError(.badURL) }
    var request = URLRequest(url: target, timeoutInterval: 15)
    request.httpShouldHandleCookies = false
    request.httpMethod = "POST"
    request.setValue(actor.header, forHTTPHeaderField: "Cookie")
    request.setValue("https://live.bilibili.com/", forHTTPHeaderField: "Referer")
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = Data("room_id=\(room)&platform=pc".utf8)
    try Task.checkCancellation()
    guard enabled() else { return }
    let (data, response) = try await webResponse(request, identity: actor, use: .role(.heartbeat))
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ServiceError("未能记录直播历史") }
    struct Receipt: Decodable { let code: Int }
    let receipt = try JSONDecoder().decode(Receipt.self, from: data)
    if receipt.code != 0 { throw ServiceError("未能记录直播历史") }
  }
}
