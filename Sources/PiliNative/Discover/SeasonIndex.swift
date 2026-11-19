import SwiftUI

struct SeasonCatalog: View {
  init(initialType: Int = 1) {
    _kind = State(initialValue: initialType)
    _visited = State(initialValue: [initialType])
  }
  @State private var visited: Set<Int>
  @State private var kind: Int
  @EnvironmentObject private var accounts: AccountContext
  private let scopes = [(1, "番剧"), (102, "全部影视"), (2, "电影"), (5, "电视剧"), (3, "纪录片"), (7, "综艺")]
  var body: some View {
    VStack(spacing: 0) {
      ChipBar(items: scopes.map(\.0), selection: $kind, title: { n in scopes.first { $0.0 == n }?.1 ?? "" })
        .padding(.vertical, 6)
      ZStack {
        ForEach(scopes.filter { visited.contains($0.0) }, id: \.0) { n, _ in
          SeasonIndexBody(
            kind: n, owner: accounts.state.owner(.role(.recommend)) ?? "",
            conditionOwner: accounts.state.active ?? "", active: n == kind
          )
          .opacity(n == kind ? 1 : 0).allowsHitTesting(n == kind).accessibilityHidden(n != kind)
        }
      }.id("\(accounts.state.owner(.role(.recommend)) ?? ""):\(accounts.state.active ?? "")")
        .onChange(of: kind) { _, n in visited.insert(n) }

    }.navigationTitle("影视索引").toolbar {
      NavigationLink { DeferredPage { SeasonCalendar() } } label: { Image(systemName: "calendar").accessibilityLabel("更新日历") }
    }
  }
}
private struct SeasonIndexBody: View {
  let kind: Int, owner: String, conditionOwner: String, active: Bool
  @State private var condition: SeasonIndexCondition?
  @State private var choice = [String: String]()
  @State private var expand = false
  @State private var retry = 0
  @State private var issue: String?
  private var scopeFields: [String: String] {
    kind == 1 ? ["season_type": "1", "type": "0"] : ["index_type": String(kind), "type": "0"]
  }
  private var identity: String {
    choice.sorted { $0.key < $1.key }.map { $0.key + "=" + $0.value }.joined(separator: "&")
  }
  var body: some View {
    Group {
      if let condition {
        PageList(
          empty: "没有符合条件的作品", grid: true, gridItemWidth: 104, autoMore: true, active: active,
          heading: AnyView(controls(condition))
        ) { cursor in
          struct Result: Decodable { let list: [Season]?, has_next: Int? }
          let page = Int(cursor ?? "1") ?? 1
          let fields = scopeFields.merging(choice) { first, _ in first }.merging([
            "page": String(page), "pagesize": "21",
          ]) { _, last in last }
          let result = try await BiliAPI.shared.read(
            "/pgc/season/index/result", fields, expectedAccount: owner, as: Result.self)
          return Page(items: result.list ?? [], next: result.has_next == 1 ? String(page + 1) : nil)
        } row: {
          SeasonTile(season: $0)
        }.id(identity)
      } else if let issue {
        PageFailure(message: issue) { retry += 1 }
      } else {
        PageLoading()
      }
    }.task(id: retry) {
      do {
        let data = try await BiliAPI.shared.read(
          "/pgc/season/index/condition", scopeFields, expectedAccount: conditionOwner,
          as: SeasonIndexCondition.self)
        try Task.checkCancellation()
        choice = data.firstChoices()
        condition = data
        issue = nil
      } catch { if !Task.isCancelled { issue = error.localizedDescription } }
    }
  }
  private func controls(_ c: SeasonIndexCondition) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      if let orders = c.order, !orders.isEmpty {
        FilterChips(items: orders.map(\.field), selection: binding("order"), title: { f in
          orders.first { $0.field == f }?.name ?? f
        })
      }
      let groups = (c.filter ?? []).filter {
        $0.values?.isEmpty == false && choice[$0.field] != nil
      }
      let visible = expand || groups.count <= 4 ? groups.count : max(1, (groups.count + 1) / 2 - 1)
      ForEach(Array(groups.prefix(visible)), id: \.field) { group in
        let values = group.values ?? []
        FilterChips(items: values.map(\.keyword), selection: binding(group.field), title: { k in
          values.first { $0.keyword == k }?.name ?? k
        })
      }
      HStack {
        if groups.count > 4 {
          Button {
            withAnimation(.snappy(duration: 0.25)) { expand.toggle() }
          } label: {
            Label(expand ? "收起筛选" : "更多筛选", systemImage: expand ? "chevron.up" : "chevron.down")
          }
        }
        Spacer()
        if choice != c.firstChoices() {
          Button("重置") { withAnimation { choice = c.firstChoices() } }
        }
      }
      .font(.footnote.weight(.medium)).buttonStyle(.plain).foregroundStyle(.tint)
      .padding(.horizontal, 16).padding(.top, 4)
    }
    .padding(.horizontal, -16)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
  private func binding(_ key: String) -> Binding<String> {
    .init(get: { choice[key] ?? "" }, set: { choice[key] = $0 })
  }
}
