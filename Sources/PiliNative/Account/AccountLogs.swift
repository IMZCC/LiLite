import SwiftUI

struct AccountLogs: View {
  enum Kind: String, CaseIterable {
    case coin = "硬币记录"
    case exp = "经验记录"
    case login = "登录记录"
  }
  let kind: Kind, uid: String
  @EnvironmentObject private var accounts: AccountContext
  struct Record: Identifiable {
    let id: Int, title: String, time: String, detail: String
    var delta: Double? = nil
  }
  struct Entry: Decodable {
    let time: String?, delta: Double?, reason: String?, ip: String?, time_at: String?, geo: String?
  }
  struct ListData: Decodable { let list: [Entry]? }
  var body: some View {
    if accounts.state.active == uid {
    PageList(empty: "暂无记录") { _ in
      let path: String
      switch kind {
      case .coin: path = "/x/member/web/coin/log"
      case .exp: path = "/x/member/web/exp/log"
      case .login: path = "/x/member/web/login/log"
      }
      let r = try await BiliAPI.shared.read(
        path, ["jsonp": "jsonp", "web_location": "333.33"], expectedAccount: uid, as: ListData.self)
      let rows = (r.list ?? []).enumerated().map { i, e in
        Record(
          id: i, title: e.reason ?? e.geo ?? "", time: e.time ?? e.time_at ?? "",
          detail: e.delta.map { $0.formatted(.number.sign(strategy: .always())) } ?? e.ip ?? "",
          delta: e.delta)
      }
      return Page(items: rows, next: nil)
    } row: { r in
      HStack(alignment: .center, spacing: 12) {
        if kind == .login {
          Image(systemName: "location.circle.fill").font(.title2).foregroundStyle(.tint)
        }
        VStack(alignment: .leading, spacing: 3) {
          Text(r.title.isEmpty ? "未知" : r.title).font(.body).lineLimit(2)
          Text(r.time).font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        Spacer(minLength: 8)
        Text(r.detail)
          .font(r.delta == nil ? .caption.monospaced() : .headline.monospacedDigit())
          .foregroundStyle(r.delta.map { $0 >= 0 ? Color.green : Color.red } ?? Color.secondary)
      }
      .padding(.vertical, 3)
    }.textSelection(.enabled).id(uid).navigationTitle(kind.rawValue)
    } else { ContentUnavailableView("账号已切换", systemImage: "person.crop.circle") }
  }
}
