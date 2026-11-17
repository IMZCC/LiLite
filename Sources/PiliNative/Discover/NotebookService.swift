import Foundation

struct NotebookRejected: LocalizedError {
  let code: Int, message: String
  var errorDescription: String? { message }
}
extension BiliAPI {
  private func notebookFields(_ oid: Int64, owner: String) async throws -> [String: String] {
    guard oid > 0, let actor = try await AccountJar.shared.current(), actor.id == owner,
      let csrf = actor.csrf
    else { throw ServiceError("账号已切换") }
    return ["oid": String(oid), "oid_type": "0", "csrf": csrf]
  }
  func notebookIDs(oid: Int64, owner: String) async throws -> [Int64] {
    let f = try await notebookFields(oid, owner: owner)
    let value = try await dynamicData("/x/note/list/archive", f, expectedAccount: owner)
    let ids = try NotebookGrant.ids(value)
    guard try await AccountJar.shared.current()?.id == owner else { throw ServiceError("账号已切换") }
    return ids
  }
  func notebookInfo(oid: Int64, id: Int64, owner: String) async throws -> NotebookRemote {
    var f = try await notebookFields(oid, owner: owner)
    f["note_id"] = String(id)
    let value = try await dynamicData("/x/note/info", f, expectedAccount: owner)
    guard try await AccountJar.shared.current()?.id == owner else { throw ServiceError("账号已切换") }
    return try NotebookRemote(value, id: id, oid: oid)
  }
  func notebookValidate(oid: Int64, note: Int64?, base: Data?, owner: String) async throws {
    let ids = try await notebookIDs(oid: oid, owner: owner)
    if let note {
      guard ids.contains(note) else { throw ServiceError("这份笔记不属于当前账号") }
      let current = try await notebookInfo(oid: oid, id: note, owner: owner)
      guard !current.locked else { throw ServiceError(current.reason ?? "当前无法编辑这份笔记") }
      guard current.base == base else { throw ServiceError("云端笔记已更改，请先重新读取") }
    } else if !ids.isEmpty {
      throw ServiceError("此视频已有云端笔记，请先重新读取")
    }
    try Task.checkCancellation()
  }
  func notebookSubmit(_ form: [String: String], owner: String, known: Int64?) async throws -> Int64
  {
    guard let account = try await AccountJar.shared.current(), account.id == owner,
      let token = account.csrf
    else { throw ServiceError("账号已切换") }
    var fields = form
    fields["csrf"] = token
    var q = URLComponents()
    q.queryItems = fields.sorted { $0.key < $1.key }.map(URLQueryItem.init)
    guard
      let body = q.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(
        using: .utf8)
    else { throw ServiceError("笔记内容无效") }
    var req = URLRequest(
      url: URL(string: "https://api.bilibili.com/x/note/add")!, timeoutInterval: 25)
    req.httpMethod = "POST"
    req.httpShouldHandleCookies = false
    req.httpBody = body
    req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    req.setValue(account.header, forHTTPHeaderField: "Cookie")
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    let (bytes, h) = try await webResponse(req, identity: account)
    let root = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
    guard (h as? HTTPURLResponse)?.statusCode == 200, let code = root?["code"] as? Int else {
      throw URLError(.badServerResponse)
    }
    if code != 0 {
      throw NotebookRejected(code: code, message: root?["message"] as? String ?? "服务未接受这份笔记")
    }
    guard let id = NotebookBlock.integer((root?["data"] as? [String: Any])?["note_id"]), id > 0,
      known.map({ $0 == id }) != false
    else { throw ServiceError("请重新读取笔记以核对提交结果") }
    return id
  }
  func notebookUpload(_ image: Data, owner: String) async throws -> String {
    guard !image.isEmpty, image.count <= 12 * 1024 * 1024,
      let actor = try await AccountJar.shared.current(), actor.id == owner, let csrf = actor.csrf
    else { throw ServiceError("图片或账号不可用") }
    let sep = "Note-" + UUID().uuidString
    var bytes = Data(
      "--\(sep)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"note.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"
        .utf8)
    bytes.append(image)
    bytes.append(
      Data(
        "\r\n--\(sep)\r\nContent-Disposition: form-data; name=\"csrf\"\r\n\r\n\(csrf)\r\n--\(sep)--\r\n"
          .utf8))
    var r = URLRequest(
      url: URL(string: "https://api.bilibili.com/x/note/image/upload")!, timeoutInterval: 35)
    r.httpMethod = "POST"
    r.httpShouldHandleCookies = false
    r.httpBody = bytes
    r.setValue("multipart/form-data; boundary=" + sep, forHTTPHeaderField: "Content-Type")
    r.setValue(actor.header, forHTTPHeaderField: "Cookie")
    r.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    let (d, h) = try await webResponse(r, identity: actor)
    let v = try JSONSerialization.jsonObject(with: d) as? [String: Any]
    guard (h as? HTTPURLResponse)?.statusCode == 200, v?["code"] as? Int == 0,
      let location = (v?["data"] as? [String: Any])?["location"] as? String,
      let url = NotebookBlock.allowedImage(location)
    else { throw ServiceError(v?["message"] as? String ?? "笔记图片上传失败") }
    guard try await AccountJar.shared.current()?.id == owner else { throw ServiceError("账号已切换") }
    return url.absoluteString
  }
  func notebookAuthorizedImage(_ url: URL, owner: String) async throws -> Data {
    guard NotebookBlock.allowedImage(url.absoluteString) == url,
      let actor = try await AccountJar.shared.current(), actor.id == owner
    else { throw ServiceError("笔记图片不可用") }
    var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
    req.httpShouldHandleCookies = false
    req.setValue(actor.header, forHTTPHeaderField: "Cookie")
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    var bound = try await AccountJar.shared.bindWeb(actor)
    req.setValue(bound.header(for: url), forHTTPHeaderField: "Cookie")
    let capture = (session.native.delegate as? CertificateSessionDelegate).map { ResponseCookieCapture(forwarding: $0) }
    var (stream, h) = try await session.native.bytes(for: req, delegate: capture)
    if let http = h as? HTTPURLResponse, let origin = http.url, WebCookieJar.webURL(origin) {
      let cookies = (capture?.cookies ?? []) + ResponseCookieOrigin.received(http)
      guard let updated = try await AccountJar.shared.mergeResponseCookies(cookies, from: origin, bound: bound, use: .role(.main)) else {
        throw ServiceError("账号已切换")
      }
      bound = updated
    }
    if let status = h as? HTTPURLResponse, (300..<400).contains(status.statusCode),
      let loc = status.value(forHTTPHeaderField: "Location").flatMap({
        URL(string: $0, relativeTo: url)?.absoluteURL
      }),
      loc.scheme == "https", loc.user == nil, loc.password == nil,
      loc.port == nil || loc.port == 443,
      let host = loc.host?.lowercased(),
      ["biliimg.com", "hdslb.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) })
    {
      var clean = URLRequest(
        url: loc, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
      clean.httpShouldHandleCookies = false
      clean.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
      (stream, h) = try await session.native.bytes(for: clean)
    }
    guard (h as? HTTPURLResponse)?.statusCode == 200, h.expectedContentLength <= 12 * 1024 * 1024
    else { throw ServiceError("笔记图片不可用") }
    var d = Data()
    for try await byte in stream {
      if d.count >= 12 * 1024 * 1024 { throw ServiceError("笔记图片过大") }
      d.append(byte)
    }
    guard try await AccountJar.shared.webMatches(bound, use: .role(.main)) else { throw ServiceError("账号已切换") }
    return d
  }
}
