import Foundation

enum NoticeKind: String, CaseIterable {
  case reply = "回复我的"
  case at = "提到我的"
  case like = "收到的赞"
  case system = "系统通知"
  var code: String? {
    switch self {
    case .like: "0"
    case .reply: "1"
    case .at: "2"
    case .system: nil
    }
  }
}
struct Notice: Identifiable {
  let number: Int64?, key: String, title: String, text: String
  var source: String?, photo: String?, time: Double?, dateText: String?, likes: Int = 0,
    muted: Bool?, group: String?
  var authors: [NoticeAuthor] = [], quotes: [String] = [], picture: String?, business: String?,
    anchored: SharedLink?
  var id: String { key }
}
struct NoticeAuthor: Decodable, Identifiable {
  let mid: Int64?, nickname: String?, avatar: String?
  var id: Int64 { mid ?? 0 }
}
struct LikeNoticePage: Decodable {
  struct Card: Decodable { let title: String?, business: String? }
  struct Cursor: Decodable { let is_end: Bool? }
  struct Who: Decodable { let mid: Int64, nickname: String?, avatar: String? }
  struct Item: Decodable, Identifiable {
    let user: Who, like_time: Double?
    var id: Int64 { user.mid }
  }
  let card: Card?, page: Cursor?, items: [Item]?
}
extension BiliAPI {
  func notices(_ kind: NoticeKind, cursor: String?, uid: String) async throws -> Page<Notice> {
    var q = ["platform": "web", "mobi_app": "web", "build": "0", "web_location": "333.40164"]
    if kind == .system {
      struct SystemItem: Decodable {
        let id: Int64?, cursor: Int64?, title: String?, content: String?, time_at: String?
      }
      q["page_size"] = "20"
      q["cursor"] = cursor
      let r = try await read(
        "/x/sys-msg/query_notify_list", q, host: "message.bilibili.com", expectedAccount: uid,
        as: [SystemItem].self)
      let rows = r.enumerated().map { i, v in
        var body = v.content ?? ""
        if let item = (try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any],
          let web = item["web"] as? String
        {
          body = web
        }
        return Notice(
          number: v.id, key: "sys:\(v.id ?? v.cursor ?? Int64(i))", title: v.title ?? "系统通知",
          text: body, dateText: v.time_at)
      }
      if cursor == nil, let first = r.first?.cursor,
        let account = try await AccountJar.shared.current(), account.id == uid,
        let csrf = account.csrf
      {
        try Task.checkCancellation()
        _ = try? await fetch(
          "/x/sys-msg/update_cursor", ["cursor": String(first), "csrf": csrf],
          host: "message.bilibili.com", expectedAccount: uid)
      }
      let n = r.count >= 20 ? r.last?.cursor.map(String.init) : nil
      return .init(items: rows, next: n == cursor ? nil : n)
    }
    struct Feed: Decodable {
      struct Cursor: Decodable { let is_end: Bool?, id: Int64?, time: Int64? }
      struct Entry: Decodable {
        struct Item: Decodable {
          let image: String?, root_reply_content: String?, subject_id: Int64?, business_id: Int?
          let title: String?, source_content: String?, target_reply_content: String?, uri: String?,
            native_uri: String?, business: String?
        }
        let id: Int64, user: NoticeAuthor?, users: [NoticeAuthor]?, item: Item?, counts: Int?,
          notice_state: Int?, like_time: Double?, reply_time: Double?, at_time: Double?
        func row(_ kind: NoticeKind, group: String? = nil) -> Notice {
          let who = user ?? users?.first
          return Notice(
            number: id, key: "\(group ?? ""):\(id)", title: who?.nickname ?? kind.rawValue,
            text: item?.source_content ?? item?.title ?? item?.target_reply_content ?? item?
              .business ?? "",
            source: [item?.native_uri, item?.uri].compactMap { $0 }.first {
              SharedLink.parse($0) != nil || httpsURL($0) != nil
            }, photo: who?.avatar, time: reply_time ?? at_time ?? like_time, likes: counts ?? 0,
            muted: notice_state.map { $0 != 0 }, group: group,
            authors: (users ?? user.map { [$0] } ?? []).filter { ($0.mid ?? 0) > 0 },
            quotes: [item?.target_reply_content, item?.root_reply_content].compactMap { $0 }.filter
            { !$0.isEmpty },
            picture: item?.image, business: item?.business,
            anchored: NoticeMarkup.reply(
              item?.native_uri, oid: item?.subject_id, business: item?.business_id))
        }
      }
      let items: [Entry]?, cursor: Cursor?
    }
    struct Likes: Decodable { let latest: Feed?, total: Feed? }
    let endpoint = kind == .reply ? "reply" : kind == .at ? "at" : "like"
    if let p = cursor?.split(separator: ":"), p.count == 2 {
      q["id"] = String(p[0])
      q[endpoint + "_time"] = String(p[1])
    }
    let feed: Feed?
    let rows: [Notice]
    if kind == .like {
      let r = try await read("/x/msgfeed/like", q, expectedAccount: uid, as: Likes.self)
      feed = r.total
      rows =
        (r.latest?.items ?? []).map { $0.row(.like, group: "最新") }
        + (r.total?.items ?? []).map { $0.row(.like, group: "累计") }
    } else {
      feed = try await read("/x/msgfeed/" + endpoint, q, expectedAccount: uid, as: Feed.self)
      rows = (feed?.items ?? []).map { $0.row(kind) }
    }
    var next: String?
    if let c = feed?.cursor, c.is_end != true, feed?.items?.isEmpty == false, let id = c.id,
      let time = c.time
    {
      next = "\(id):\(time)"
    }
    return .init(items: rows, next: next == cursor ? nil : next)
  }
  func likedBy(_ card: Int64, page: Int, last: Int64, uid: String) async throws -> LikeNoticePage {
    try await read(
      "/x/msgfeed/like_detail",
      [
        "card_id": String(card), "pn": String(page), "last_mid": String(last), "platform": "web",
        "build": "0", "mobi_app": "web", "web_location": "333.40164",
      ], expectedAccount: uid, as: LikeNoticePage.self)
  }
  func changeNotice(_ kind: NoticeKind, id: Int64, uid: String, mute: Bool? = nil) async throws {
    guard id > 0, let account = try await AccountJar.shared.current(), account.id == uid,
      let csrf = account.csrf
    else { throw ServiceError("请先登录") }
    if let code = kind.code {
      var fields = [
        "tp": code, "id": String(id), "build": "0", "mobi_app": "web", "csrf_token": csrf,
      ]
      if let mute {
        guard kind == .like else { throw ServiceError("此通知不支持静音") }
        fields["notice_state"] = mute ? "1" : "0"
        fields["platform"] = "web"
      }
      try await submit(
        mute == nil ? "/x/msgfeed/del" : "/x/msgfeed/notice", fields, expectedAccount: uid)
    } else {
      guard mute == nil else { throw ServiceError("此通知不支持静音") }
      var c = URLComponents()
      c.scheme = "https"
      c.host = "message.bilibili.com"
      c.path = "/x/sys-msg/del_notify_list"
      c.queryItems = [.init(name: "mobi_app", value: "iphone"), .init(name: "csrf", value: csrf)]
      guard let url = c.url else { throw URLError(.badURL) }
      var request = URLRequest(url: url, timeoutInterval: 18)
      request.httpMethod = "POST"
      request.httpShouldHandleCookies = false
      request.setValue(account.header, forHTTPHeaderField: "Cookie")
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
      request.httpBody = try JSONSerialization.data(
        withJSONObject: [
          "csrf": csrf, "ids": [id], "station_ids": [Int](), "type": 4, "mobi_app": "iphone",
        ] as [String: Any])
      let (data, raw) = try await webResponse(request, identity: account)
      struct Result: Decodable { let code: Int, message: String? }
      let result = try JSONDecoder().decode(Result.self, from: data)
      guard (raw as? HTTPURLResponse)?.statusCode == 200, result.code == 0 else {
        throw ServiceError(result.message ?? "删除失败")
      }
    }
  }
}
