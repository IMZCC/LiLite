import Foundation
import SwiftUI

struct VisibilityRequest: Identifiable {
  enum Target {
    case moment(String)
    case reply(oid: Int64, kind: Int, root: Int64, id: Int64)
  }
  let id = UUID()
  let uid: String, target: Target, delay: Int
  init(_ target: Target, user: String, after delay: Int = 0) {
    self.target = target
    uid = user
    self.delay = delay
  }
}
private enum VisibleRead { case found, missing, incomplete }
extension BiliAPI {
  private func visibilityData(
    _ path: String, _ query: [String: String], _ request: VisibilityRequest, owner: Bool
  ) async throws -> (Int, [String: Any]) {
    guard let account = try await AccountJar.shared.current(), account.id == request.uid else {
      throw ServiceError("账号已切换")
    }
    guard
      ["/x/v2/reply/main", "/x/v2/reply/reply", "/x/polymer/web-dynamic/v1/detail"].contains(path)
    else { throw URLError(.unsupportedURL) }
    var c = URLComponents()
    c.scheme = "https"
    c.host = "api.bilibili.com"
    c.path = path
    c.queryItems = query.map(URLQueryItem.init)
    guard let url = c.url else { throw URLError(.badURL) }
    var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
    r.httpShouldHandleCookies = false
    r.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    r.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1",
      forHTTPHeaderField: "User-Agent")
    if owner { r.setValue(account.header, forHTTPHeaderField: "Cookie") }
    let bytes: Data, res: URLResponse
    if owner { (bytes, res) = try await webResponse(r, identity: account) }
    else { (bytes, res) = try await session.data(for: r) }
    try Task.checkCancellation()
    guard (res as? HTTPURLResponse)?.statusCode == 200,
      let response = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
      let code = response["code"] as? Int
    else { throw ServiceError("暂时无法读取可见性信息") }
    // Only treat explicit object-not-found results as absence; login/rate/network errors are inconclusive.
    if code != 0 && ![-404, 12022].contains(code) {
      throw ServiceError(response["message"] as? String ?? "服务暂未返回结果")
    }
    return (code, response["data"] as? [String: Any] ?? [:])
  }
  func visibility(_ request: VisibilityRequest) async throws -> String {
    typealias M = [String: Any]
    func number(_ value: Any?) -> Int64? {
      (value as? NSNumber)?.int64Value ?? (value as? String).flatMap(Int64.init)
    }
    func rows(_ data: M) -> [Int64] {
      (data["replies"] as? [M] ?? []).compactMap { number($0["rpid"] ?? $0["rpid_str"]) }
    }
    switch request.target {
    case .moment(let id):
      let q = [
        "id": id, "features": "itemOpusStyle", "timezone_offset": "-480",
        "web_location": "333.1330",
      ]
      for owner in [false, true] {
        let (code, data) = try await visibilityData(
          "/x/polymer/web-dynamic/v1/detail", q, request, owner: owner)
        if code == 0, let item = data["item"] as? M, item["id_str"] as? String == id {
          return owner ? "当前账号可见，游客未找到这条动态" : "游客可以查看这条动态"
        }
      }
      return "未找到这条动态"
    case .reply(let oid, let kind, let root, let id):
      let base = ["oid": String(oid), "type": String(kind)]
      let isRoot = root == 0 || root == id
      if isRoot {
        let q = base.merging(["mode": "2", "pagination_str": "{\"offset\":\"\"}"]) { $1 }
        let (_, data) = try await visibilityData("/x/v2/reply/main", q, request, owner: false)
        if rows(data).contains(id) { return "游客可以在评论列表看到这条评论" }
      }
      func lookup(_ owner: Bool) async throws -> VisibleRead {
        var seen = Set<Int64>()
        for page in 1...50 {
          let q = base.merging(["root": String(isRoot ? id : root), "pn": String(page), "ps": "20"])
          { $1 }
          let (code, data) = try await visibilityData("/x/v2/reply/reply", q, request, owner: owner)
          if code != 0 { return .missing }
          if isRoot {
            let row = data["root"] as? M
            guard let row, let key = number(row["rpid"] ?? row["rpid_str"]) else {
              return .incomplete
            }
            return key == id ? .found : .missing
          }
          let ids = rows(data)
          if ids.contains(id) { return .found }
          let count = number((data["page"] as? M)?["count"])
          if ids.isEmpty || count.map({ Int64(page * 20) >= $0 }) == true { return .missing }
          let added = ids.contains { !seen.contains($0) }
          seen.formUnion(ids)
          if !added { return .incomplete }
        }
        return .incomplete
      }
      switch try await lookup(false) {
      case .found: return isRoot ? "游客可以通过直达入口看到这条评论" : "游客可以看到这条楼中楼回复"
      case .incomplete: return "回复较多，尚未确认这条评论是否可见"
      case .missing: break
      }
      switch try await lookup(true) {
      case .found: return "当前账号可见，游客未找到这条评论"
      case .missing: return "未找到这条评论"
      case .incomplete: return "尚未确认这条评论是否可见"
      }
    }
  }
}
struct VisibilityPanel: View {
  let request: VisibilityRequest
  @EnvironmentObject private var accounts: AccountContext
  @Environment(\.dismiss) private var dismiss
  @State private var result: String?
  @State private var issue: String?
  @State private var retry = 0
  var body: some View {
    PiliNavigationStack {
      List {
        if let result {
          Text(result)
        } else if let issue {
          Text(issue).foregroundStyle(.secondary)
        } else {
          ProgressView("正在检查可见性")
        }
        if result != nil || issue != nil { Button("重新检查") { retry += 1 } }
        if case .reply = request.target,
          let url = URL(string: "https://www.bilibili.com/h5/comment/appeal")
        {
          NavigationLink("评论申诉") { DeferredPage { SitePage(url: url) } }
        }
      }.navigationTitle("公开可见性").toolbar { Button("完成") { dismiss() } }
    }
    .task(id: retry) {
      result = nil
      issue = nil
      do {
        if retry == 0, request.delay > 0 { try await Task.sleep(for: .seconds(request.delay)) }
        let text = try await BiliAPI.shared.visibility(request)
        try Task.checkCancellation()
        if accounts.state.active == request.uid { result = text }
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
    .onChange(of: accounts.state.active) { _, u in if u != request.uid { dismiss() } }
  }
}
