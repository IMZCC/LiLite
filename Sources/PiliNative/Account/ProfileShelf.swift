import SwiftUI

extension BiliAPI {
  func profileShelf(_ section: MineSection, uid: String, cursor: String?) async throws -> Page<
    ProfileShelfItem
  > {
    let p = Int(cursor ?? "1") ?? 1
    switch section {
    case .later:
      let response = try await later(page: p, keyword: "", uid: uid)
      return .init(
        items: response.items.map { v in
          .init(
            id: v.id, title: v.name, caption: v.caption, cover: v.cover,
            target: v.route.map(ProfileShelfItem.Target.link) ?? .unavailable(v.id))
        }, next: response.next, reportedTotal: response.reportedTotal)
    case .favorite, .subscribed:
      struct PageData: Decodable {
        struct Row: Decodable {
          let id: Int64, title: String?, cover: String?, type: Int?, state: Int?, media_count: Int?
        }
        let list: [Row]?, has_more: Bool?, count: Int?
      }
      var q = ["up_mid": uid, "pn": String(p), "ps": "20"]
      if section == .subscribed { q["platform"] = "web" }
      let reply = try await read(
        section == .favorite ? "/x/v3/fav/folder/created/list" : "/x/v3/fav/folder/collected/list",
        q, expectedAccount: uid, as: PageData.self)
      let raw = reply.list ?? []
      return .init(
        items: raw.filter { $0.id > 0 }.map { row in
          let key = "\(row.type ?? 0):\(row.id)"
          let kind = row.type == 21 ? "合集" : "收藏夹"
          return .init(
            id: key, title: row.title ?? kind,
            caption: row.state == 1 ? "已失效" : "\(kind) · \(row.media_count ?? 0) 项",
            cover: row.cover.flatMap(httpsURL),
            target: row.state == 1
              ? .unavailable(key) : row.type == 21 ? .season(row.id) : .folder(row.id))
        },
        next: !raw.isEmpty
          && (reply.has_more ?? reply.count.map { p * 20 < $0 } ?? (raw.count == 20))
          ? String(p + 1) : nil, reportedTotal: reply.count)
    case .history:
      let fields = cursor?.split(separator: ":").map(String.init) ?? []
      let page = try await read(
        "/x/web-interface/history/cursor",
        ["type": "all", "ps": "20", "max": fields.first ?? "0", "view_at": fields.last ?? "0"],
        expectedAccount: uid, as: MineHistoryPage.self)
      let raw = page.list ?? []
      let next = page.cursor.flatMap { point -> String? in
        guard let oid = point.max, let at = point.view_at, at > 0 else { return nil }
        return "\(oid):\(at)"
      }
      return .init(items: raw.compactMap(\.entry), next: raw.isEmpty || next == cursor ? nil : next)
    }
  }
}

struct ProfileShelf: View {
  let field: MineSection, uid: String
  @ObservedObject private var model: ProfileShelfState
  init(field: MineSection, uid: String) {
    self.field = field; self.uid = uid
    model = ProfileStore.shared.shelf(field, uid: uid)
  }
  private var rows: [ProfileShelfItem] { model.rows }
  private var total: Int? { model.total }
  private var cursor: String? { model.cursor }
  private var ready: Bool { model.ready }
  private var loading: Bool { model.loading }
  private var issue: String? { model.issue }
  private var identity: String { "\(field.rawValue):\(uid)" }
  var body: some View {
    Section {
      if !rows.isEmpty {
        ScrollView(.horizontal) {
          LazyHStack(alignment: .top, spacing: 12) {
            ForEach(rows) { row in
              ProfileShelfLink(row: row) {
                VStack(alignment: .leading, spacing: 4) {
                  RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous).fill(.quaternary).aspectRatio(
                    1.7, contentMode: .fit
                  )
                  .overlay {
                    SiteThumbnail(url: row.cover) {
                      $0.resizable().scaledToFill()
                    } placeholder: {
                      Color.clear
                    }
                  }.clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
                  .overlay(alignment: .bottom) {
                    // Plain shapes: a system ProgressView per thumbnail was a platform view each,
                    // and the first one drawn set the GPU renderer up on the main thread.
                    if let v = row.progress {
                      Rectangle().fill(Color.accentColor)
                        .frame(height: 3)
                        .scaleEffect(x: min(1, max(0, v)), y: 1, anchor: .leading)
                        .accessibilityElement().accessibilityLabel("观看进度")
                        .accessibilityValue("\(Int((min(1, max(0, v)) * 100).rounded()))%")
                    }
                  }
                  Text(row.title).font(.footnote).lineLimit(2)
                  if let text = row.caption, !text.isEmpty {
                    Text(text).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                  }
                }
                // Three cards fill the row on a phone; wider rows fit more of the same size.
                .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in
                  let count = max(3, ((length + 12) / 150).rounded(.down))
                  return max(0, (length - 12 * (count - 1)) / count)
                }
                .contentShape(Rectangle())
              }.buttonStyle(.plain)
            }
            if cursor != nil && issue == nil {
              ProgressView().padding(.horizontal, 16).task(id: cursor) { await model.loadMore() }
            }
          }
        }.scrollIndicators(.hidden)
      } else if !ready && issue == nil {
        ProgressView()
      }
      if let issue {
        Text(issue).font(.footnote).foregroundStyle(.secondary)
        Button("重试") { Task { await model.retry() } }
      }
    } header: {
      if !ready || !rows.isEmpty || issue != nil {
        HStack {
          NavigationLink {
            destination
          } label: {
            HStack(spacing: 4) {
              Text(field.label)
              if let total { Text(String(total)).foregroundStyle(.secondary) }
              Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
          }
          Spacer()
          Button { Task { await model.refresh(force: true) } } label: {
            Image(systemName: "arrow.clockwise").font(.footnote.weight(.medium)).foregroundStyle(.secondary)
          }
          .accessibilityLabel("刷新" + field.label).disabled(loading)
        }
        .font(.subheadline.weight(.semibold))
      }
    }.task(id: identity) {
      await model.refresh()
    }
  }
  @ViewBuilder private var destination: some View {
    switch field {
    case .favorite: FolderList(uid: uid)
    case .history: ProfileFullHistory(uid: uid)
    case .later: CloudLibraryView(kind: .later, uid: uid)
    case .subscribed: Subscriptions(uid: uid)
    }
  }
}
private struct ProfileShelfLink<Content: View>: View {
  let row: ProfileShelfItem
  @ViewBuilder let label: () -> Content
  var body: some View {
    switch row.target {
    case .link(let l):
      LazyLink {
        LinkDestination(item: l)
      } label: {
        label()
      }
    case .folder(let id):
      LazyLink {
        FavoriteFolderScreen(id: id)
      } label: {
        label()
      }
    case .season(let id):
      LazyLink {
        SubscriptionCollection(item: .init(id: id, type: 21, title: row.title))
      } label: {
        label()
      }
    case .courseHistory(let id, let ep, let aid, let seconds):
      LazyLink {
        HistoryCourseLink(id: id, byEpisode: ep, aid: aid, seconds: seconds)
      } label: {
        label()
      }
    case .unavailable: label().foregroundStyle(.secondary)
    }
  }
}
