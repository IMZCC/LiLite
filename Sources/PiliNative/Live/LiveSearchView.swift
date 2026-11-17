import SwiftUI

struct LiveSearchView: View {
  var initial = ""
  @State private var text = ""
  @State private var term = ""
  @State private var scope = LiveSearchScope.room
  @State private var counts: [String: Int] = [:]
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    VStack(spacing: 0) {
      ChipBar(items: LiveSearchScope.allCases, selection: $scope, title: { k in
        k.rawValue + (counts[k.rawValue].map { " \($0)" } ?? "")
      }).padding(.vertical, 6)
      if term.isEmpty {
        ContentUnavailableView("搜索直播间或主播", systemImage: "magnifyingglass")
      } else {
        PageList(empty: "没有搜索结果") { cursor in
          let page = Int(cursor ?? "1") ?? 1
          let kind = scope
          let keyword = term
          let viewer = accounts.state.owner(.role(.recommend)) ?? ""
          let f = try await BiliAPI.shared.sign([
            "keyword": keyword, "search_type": kind.service, "page": String(page),
            "page_size": "20", "platform": "pc",
          ])
          let result = try await BiliAPI.shared.read(
            "/x/web-interface/wbi/search/type", f, expectedAccount:viewer, as: LiveSearchPayload.self)
          let r = try result.page(scope: kind, number: page, size: 20,keyword:keyword)
          try Task.checkCancellation()
          guard viewer == (accounts.state.owner(.role(.recommend)) ?? "") else {throw CancellationError()}
          if scope == kind && keyword == term { counts[kind.rawValue] = r.total }
          return Page(items: r.rows, next: r.next)
        } row: { (r: LiveSearchPayload.Hit) in
          if scope == .room {
            let row = MediaRow(
              cover: (r.picture ?? r.face).flatMap(httpsURL),
              title: r.title.isEmpty ? r.name : r.title, badge: "直播",
              subtitle: [r.name, r.area].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
              detail: r.audience.map { "\($0.formatted(.number.notation(.compactName))) 人气" })
            if let room = r.room {
              PlainRowLink { LivePlayer(id: room, title: r.title.isEmpty ? r.name : r.title) } label: { row }
            } else { row }
          } else {
            let live = r.live == true
            let row = HStack(spacing: 12) {
              SiteThumbnail(url: (r.face ?? r.picture).flatMap(httpsURL)) { $0.resizable().scaledToFill() } placeholder: {
                Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.quaternary)
              }
              .frame(width: 48, height: 48).clipShape(Circle())
              .overlay { if live { Circle().stroke(Color.pink, lineWidth: 2).padding(-3) } }
              VStack(alignment: .leading, spacing: 3) {
                Text(r.name).font(.body.weight(.medium)).lineLimit(1)
                Text([r.area, r.fans.map { "\($0.formatted(.number.notation(.compactName))) 粉丝" }]
                  .compactMap { $0 }.joined(separator: " · "))
                  .font(.caption).foregroundStyle(.secondary)
              }
              Spacer(minLength: 0)
              if live {
                Text("直播中").font(.caption2.weight(.bold)).foregroundStyle(.white)
                  .padding(.horizontal, 7).padding(.vertical, 3).background(Color.pink, in: Capsule())
              }
            }.padding(.vertical, 2).contentShape(Rectangle())
            if live, let room = r.room {
              PlainRowLink { LivePlayer(id: room, title: r.title.isEmpty ? r.name : r.title) } label: { row }
            } else if let uid = r.uid {
              PlainRowLink { CreatorSpace(mid: uid, name: r.name) } label: { row }
            } else { row }
          }
        }.id("\(scope.rawValue):\(term):\(accounts.state.owner(.role(.recommend)) ?? "")")
      }
    }.navigationTitle("直播搜索")
      .searchable(text: $text, placement: .navigationBarDrawer(displayMode: .always), prompt: "直播间或主播")
      .onSubmit(of: .search) {
        term = text.trimmingCharacters(in: .whitespacesAndNewlines)
        counts = [:]
      }
      .onChange(of: accounts.state.owner(.role(.recommend))) { _,_ in counts=[:] }
      .onChange(of: text) { _, v in
        if v.isEmpty {
          term = ""
          counts = [:]
        }
      }
      .onAppear {
        if text.isEmpty && term.isEmpty && !initial.isEmpty {
          text = initial
          term = initial
        }
      }
  }
}
