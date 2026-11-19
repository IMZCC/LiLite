import PiliWire
import SwiftUI

enum MomentPanel: String, CaseIterable {
  case reposts = "转发"
  case replies = "评论"
  case likes = "点赞"
}

struct DynamicActivityList: View {
  let id: String
  var panel: MomentPanel? = nil
  var heading: AnyView? = nil, controls: AnyView? = nil
  var title = "动态互动"
  var updated: ((Int64) -> Void)? = nil
  @EnvironmentObject private var accounts: AccountContext
  @State private var ownPanel = MomentPanel.likes
  @State private var total: Int64?
  private var active: MomentPanel { panel ?? ownPanel }
  private var ownPicker: some View {
    ChipBar(items: [MomentPanel.likes, .reposts], selection: $ownPanel, title: \.rawValue)
      .listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
  }
  private func count(_ n: Int64, _ cursor: String?, _ uid: String?) throws {
    try Task.checkCancellation()
    guard accounts.state.active == uid else { throw CancellationError() }
    total = n
    updated?(n)
  }
  private func member(_ p: DynamicGateway.Person) -> ReplyAuthor {
    .init(
      name: p.name.isEmpty ? "UID " + String(p.id) : p.name, avatar: p.face,
      badge: p.verify.map { .init(type: $0, desc: nil) }, pendant: p.pendant,
      vipStatus: p.vipStatus, vipType: p.vipType,
      card: p.cardURL.isEmpty
        ? nil : .init(image: p.cardURL, number: p.fanNumber, prefix: p.fanPrefix, color: p.fanColor)
    )
  }
  @ViewBuilder private func person(_ p: DynamicGateway.Person) -> some View {
    let author = member(p)
    if p.id > 0 {
      LazyLink {
        CreatorSpace(mid: p.id, name: author.uname ?? "")
      } label: {
        ReplyAuthorLabel(member: author)
      }
    } else {
      ReplyAuthorLabel(member: author)
    }
    if p.level > 0 || p.senior {
      UserLevelBadge(level: Int(p.level), height: 10, hardcore: p.senior)
    }
    Spacer(minLength: 0)
    ReplyCardBadge(card: author.card)
  }
  var body: some View {
    let uid = accounts.state.active
    VStack(alignment: .leading) {
      if panel == nil {
        ownPicker.padding(.horizontal)
        if let total {
          Text("\(total) 条").font(.caption).foregroundStyle(.secondary).padding(.horizontal)
        }
      } else if heading == nil, let controls {
        controls.padding(.horizontal)
      }
      if active == .reposts {
        PageList(empty: "暂无转发", heading: heading, controls: heading == nil ? nil : controls) {
          cursor in
          let r = try await BiliAPI.shared.socialService(for: uid).reposts(id, cursor: cursor)
          try count(r.total, cursor, uid)
          return Page(items: r.rows, next: r.next)
        } row: { r in
          VStack(alignment: .leading, spacing: 6) {
            HStack { person(r.person) }
            let nodes = r.body.compactMap(RichNode.init(activity:))
            if !nodes.isEmpty {
              DynamicRichContent(nodes: nodes, maxLines: 8, permitsPreview: true, dynamicID: r.id)
            }
            PlainRowLink {
              DynamicDetail(id: r.id)
            } label: {
              Text(nodes.isEmpty && !r.text.isEmpty ? r.text : "查看转发动态").lineLimit(5)
            }.piliTapFeedback()
            if !r.person.when.isEmpty {
              Text(r.person.when).font(.caption).foregroundStyle(.secondary)
            }
          }.buttonStyle(.borderless)
        }
      } else {
        PageList(empty: "暂无点赞", heading: heading, controls: heading == nil ? nil : controls) {
          cursor in
          let r = try await BiliAPI.shared.socialService(for: uid).likes(id, cursor: cursor)
          try count(r.total, cursor, uid)
          return Page(items: r.rows, next: r.next)
        } row: { p in
          VStack(alignment: .leading, spacing: 3) {
            HStack { person(p) }
            if !p.sign.isEmpty { Text(p.sign).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            if !p.when.isEmpty { Text(p.when).font(.caption).foregroundStyle(.secondary) }
          }.buttonStyle(.borderless)
        }
      }
    }.id("\(id):\(uid ?? ""):\(active.rawValue)").navigationTitle(title)
      .onChange(of: ownPanel) { _, _ in total = nil }
  }
}

private extension RichNode {
  init?(activity part: DynamicGateway.Inline) {
    switch part {
    case .word(let text):
      guard !text.isEmpty else { return nil }; self.init(text: text)
    case let .link(text, raw):
      let route = SharedLink.parse(raw).map(Target.route) ?? GalleryPicture.source(raw).map(Target.url)
      self.init(text: text.isEmpty ? raw : text, target: route)
    case let .emote(text, image, size):
      guard let url = GalleryPicture.source(image) else { self.init(text: text); return }
      self.init(text: text, emote: .init(name: text, url: url, size: min(3, max(1,size)),
        jump: nil, jumpTitle: nil, animation: nil))
    case let .vote(text, id): self.init(text: text.isEmpty ? "投票" : text, target: .vote(id))
    case .pictures(let rows):
      let images = rows.compactMap { p -> GalleryPicture? in
        guard let url = GalleryPicture.source(p.url) else { return nil }
        return GalleryPicture(url, motion: GalleryPicture.source(p.movie))
      }
      guard !images.isEmpty else { return nil }
      self.init(text: "查看图片", target: .gallery(images))
    }
  }
}
