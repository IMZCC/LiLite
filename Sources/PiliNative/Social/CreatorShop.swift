import SwiftUI

struct CreatorGoods: Decodable, Identifiable {
  struct Cover: Decodable { let url: String? }
  struct Badge: Decodable { let title: String? }
  struct Price: Decodable { let priceSymbol: String?, pricePrefix: String?, netPrice: String? }
  struct Benefit: Decodable { let prefix: String?, amount: String? }
  let cover: Cover?, title: String?, cardUrl: String?, itemSourceName: String?,
    belowLabels: [Badge]?, netPrice: Price?, benefitInfos: [Benefit]?
  var id: String { cardUrl ?? (title ?? "") + (cover?.url ?? "") }
  static func link(_ text: String) -> URL? {
    if let direct = httpsURL(text), direct.user == nil, direct.password == nil { return direct }
    guard let c = URLComponents(string: text), c.scheme == "bilibili", c.host == "mall",
      c.path == "/web",
      let raw = c.queryItems?.first(where: { $0.name == "url" })?.value, let u = httpsURL(raw),
      u.user == nil, u.password == nil
    else { return nil }
    return u
  }
}
extension BiliAPI {
  struct ShopPage: Decodable {
    let data: [CreatorGoods]?, showMoreTab: Bool?, clickUrl: String?, showMoreDesc: String?,
      haveNextPage: Bool?, nextSearchAfter: Int64?
  }
  func creatorGoods(mid: Int64, after: Int64) async throws -> ShopPage {
    guard mid > 0, after >= 0 else { throw ServiceError("商品目录无效") }
    let source = "cps_productTab_\(mid)"
    var q = URLRequest(
      url: URL(string: "https://mall.bilibili.com/community-hub/small_shop/feed/tab/item")!,
      timeoutInterval: 15)
    q.httpMethod = "POST"
    q.httpShouldHandleCookies = false
    q.setValue("application/json", forHTTPHeaderField: "Content-Type")
    q.setValue("https://mall.bilibili.com/", forHTTPHeaderField: "Referer")
    q.setValue("PiliNative/1.0 (iOS)", forHTTPHeaderField: "User-Agent")
    q.httpBody = try JSONSerialization.data(
      withJSONObject: [
        "from": source, "msource": source, "searchAfter": after, "pageSize": 8,
        "upMid": String(mid),
      ] as [String: Any])
    let (bytes, response) = try await session.data(for: q)
    struct Envelope: Decodable { let code: Int, message: String?, data: ShopPage? }
    let r = try JSONDecoder().decode(Envelope.self, from: bytes)
    guard (response as? HTTPURLResponse)?.statusCode == 200, r.code == 0, let page = r.data else {
      throw ServiceError(r.message ?? "商品目录未载入")
    }
    return page
  }
}
struct CreatorShop: View {
  let mid: Int64
  @State private var destination: URL?
  @State private var moreTitle = "逛逛小店"
  var body: some View {
    VStack {
      if let destination {
        NavigationLink(moreTitle) { SitePage(url: destination) }.padding(.horizontal)
      }
      PageList(empty: "小店暂无商品") { cursor in
        let position = Int64(cursor ?? "0") ?? 0
        let page = try await BiliAPI.shared.creatorGoods(mid: mid, after: position)
        try Task.checkCancellation()
        if cursor == nil {
          destination = page.showMoreTab == true ? page.clickUrl.flatMap(CreatorGoods.link) : nil
          moreTitle = page.showMoreDesc.flatMap { $0.isEmpty ? nil : $0 } ?? "逛逛小店"
        }
        let rows = page.data ?? []
        let next =
          page.haveNextPage == true && !rows.isEmpty
          ? page.nextSearchAfter.flatMap { $0 != position && $0 > 0 ? String($0) : nil } : nil
        return Page(items: rows, next: next)
      } row: { item in
        if let url = item.cardUrl.flatMap(CreatorGoods.link) {
          PlainRowLink {
            SitePage(url: url)
          } label: {
            row(item)
          }
        } else {
          row(item)
        }
      }
    }.navigationTitle("UP 主的小店")
  }
  private func row(_ item: CreatorGoods) -> some View {
    HStack {
      if let img = item.cover?.url.flatMap(httpsURL) {
        SiteThumbnail(url: img) {
          $0.resizable().scaledToFill()
        } placeholder: {
          Color.clear
        }.frame(width: 76, height: 76).clipped()
      }
      VStack(alignment: .leading, spacing: 4) {
        Text(item.title ?? "商品").piliFont(.headline)
        if let p = item.netPrice {
          Text([p.pricePrefix, p.priceSymbol, p.netPrice].compactMap { $0 }.joined())
            .foregroundStyle(.tint)
        }
        let tags =
          (item.belowLabels ?? []).compactMap(\.title)
          + (item.benefitInfos ?? []).map { [$0.prefix, $0.amount].compactMap { $0 }.joined() }
        if !tags.isEmpty { Text(tags.joined(separator: " · ")).piliFont(.caption) }
        if let from = item.itemSourceName, !from.isEmpty {
          Text(from).piliFont(.caption).foregroundStyle(.secondary)
        }
      }
    }
  }
}
