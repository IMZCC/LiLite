import SwiftUI

extension BiliAPI {
  struct Trend: Decodable, Identifiable {
    let keyword: String
    let show_name: String?, icon: String?, show_live_icon: Bool?, recommend_reason: String?
    var id: String { keyword }
    var title: String { show_name ?? keyword }
  }
  struct TrendSheet: Decodable { let list: [Trend]?, top_list: [Trend]? }
  func trends(limit: Int = 10, owner: String?) async throws -> TrendSheet {
    try await read(
      "/x/v2/search/trending/ranking", ["limit": String(limit)], expectedAccount: owner,
      as: TrendSheet.self)
  }
}
struct TrendLabel: View {
  let trend: BiliAPI.Trend
  var number: Int? = nil
  var body: some View {
    HStack(spacing: 9) {
      if let number {
        Text("\(number)").font(.subheadline.monospacedDigit()).foregroundStyle(
          number <= 3 ? .red : .secondary)
      }
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(trend.title)
          if trend.show_live_icon == true {
            Image(systemName: "dot.radiowaves.left.and.right").accessibilityLabel("直播")
          }
          if let u = trend.icon.flatMap(httpsURL) {
            SiteThumbnail(url: u) {
              $0.resizable().scaledToFit()
            } placeholder: {
              Color.clear
            }.frame(maxWidth: 28, maxHeight: 16)
          }
        }
        if let reason = trend.recommend_reason, !reason.isEmpty {
          Text(reason).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
}
struct TrendingSearchPage: View {
  let select: (String) -> Void
  @Environment(\.dismiss) private var dismiss
  @EnvironmentObject private var accounts: AccountContext
  @State private var data: BiliAPI.TrendSheet?
  @State private var error: String?
  @State private var attempt = 0
  private var owner: String { accounts.state.owner(.role(.recommend)) ?? "" }
  var body: some View {
    List {
      if let error {
        PageFailure(message: error) { attempt += 1 }
      }
      if let data {
        if let pins = data.top_list, !pins.isEmpty {
          Section("置顶") { ForEach(pins) { t in row(t, nil) } }
        }
        Section("热搜榜") {
          ForEach(Array((data.list ?? []).enumerated()), id: \.element.id) { i, t in row(t, i + 1) }
        }
      } else if error == nil {
        PageLoading()
      }
    }.navigationTitle("哔哩哔哩热搜").task(id: "\(owner):\(attempt)") { await load() }.piliRefreshable {
      await load()
    }
  }
  private func row(_ t: BiliAPI.Trend, _ n: Int?) -> some View {
    Button {
      dismiss()
      select(t.keyword)
    } label: {
      TrendLabel(trend: t, number: n)
    }
  }
  @MainActor private func load() async {
    let identity = owner
    data = nil
    error = nil
    do {
      let result = try await BiliAPI.shared.trends(limit: 30, owner: identity)
      try Task.checkCancellation()
      guard owner == identity else { return }
      data = result
    } catch {
      if !Task.isCancelled && owner == identity { self.error = error.localizedDescription }
    }
  }
}
