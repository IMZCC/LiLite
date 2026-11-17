import SwiftUI

struct MomentDestinationView: View {
  let destination: MomentDestination
  var body: some View {
    switch destination {
    case .native(let r): LinkDestination(item: r)
    case .web(let u): SitePage(url: u)
    }
  }
}
struct MomentResourceViews: View {
  let values: MomentResources, dynamic: String
  private struct Cover: Identifiable {
    let url: URL
    var id: URL { url }
  }
  @State private var selected: Cover?
  var body: some View {
    ForEach(Array(values.cards.enumerated()), id: \.offset) { _, card in
      Group {
        if let d = card.target {
          NavigationLink {
            MomentDestinationView(destination: d)
          } label: {
            label(card)
          }.buttonStyle(.borderless)
        } else {
          label(card)
        }
      }.contextMenu { if let u = card.cover { Button("查看或保存封面") { selected = .init(url: u) } } }
    }
    .piliSheet(item: $selected) { cover in
      PiliNavigationStack {
        NativeGallery([.init(cover.url)]).toolbar { Button("完成") { selected = nil } }
      }
    }
    if !values.pictures.isEmpty {
      ScrollView(.horizontal) {
        LazyHStack {
          ForEach(values.pictures.indices, id: \.self) { i in
            GalleryLink(values.pictures, index: i) {
              GalleryThumb(photo: values.pictures[i]).frame(height: 120)
            }
          }
        }
      }
    }
    if let reserve = values.reserve {
      MomentReservationView(dynamic: dynamic, initial: reserve).id(
        dynamic + ":" + String(reserve.id))
    }
  }
  private func label(_ c: MomentResources.Card) -> some View {
    MediaRow(cover: c.cover, title: c.title, subtitle: c.sub.isEmpty ? nil : c.sub, thumbWidth: 120)
      .padding(8)
      .background(Color(uiColor: .secondarySystemBackground),
        in: RoundedRectangle(cornerRadius: 14, style: .continuous))
  }
}
private struct MomentReservationView: View {
  let dynamic: String, initial: MomentReservation
  @EnvironmentObject private var accounts: AccountContext
  @State private var value: MomentReservation
  @State private var busy = false
  @State private var issue: String?
  @State private var needsRead = false
  init(dynamic: String, initial: MomentReservation) {
    self.dynamic = dynamic
    self.initial = initial
    _value = State(initialValue: initial)
  }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label(value.title, systemImage: "calendar")
      let info = [value.sub1, value.sub2].filter { !$0.isEmpty }.joined(separator: " · ")
      if !info.isEmpty { Text(info).piliFont(.caption).foregroundStyle(.secondary) }
      if !value.prize.isEmpty {
        if let t = value.prizeLink {
          NavigationLink {
            MomentDestinationView(destination: t)
          } label: {
            Label(value.prize, systemImage: "gift")
          }
        } else {
          Text(value.prize)
        }
      }
      if let target = value.jump {
        NavigationLink(value.buttonLabel) { MomentDestinationView(destination: target) }
      } else if value.buttonType != nil {
        if let uid = accounts.state.active {
          Button(needsRead ? "查看预约状态" : value.buttonLabel) { Task { await update(uid) } }.disabled(
            busy || (!needsRead && value.intent(dynamic: dynamic) == nil))
        } else if value.intent(dynamic: dynamic) != nil {
          NavigationLink("登录后预约") { QRLoginView() }
        } else {
          Text(value.buttonLabel).foregroundStyle(.secondary)
        }
      }
      if let issue { Text(issue).piliFont(.caption).foregroundStyle(.secondary) }
    }.onChange(of: initial) { _, v in
      if !busy {
        value = v
        issue = nil
        needsRead = false
      }
    }
    .onChange(of: accounts.state.active) { _, _ in
      value = initial
      issue = nil
      needsRead = false
    }
  }
  @MainActor private func update(_ uid: String) async {
    guard !busy, uid == accounts.state.active else { return }
    busy = true
    defer { busy = false }
    do {
      let current = try await BiliAPI.shared.viewerReservation(
        dynamic: dynamic, rid: initial.id, owner: uid)
      guard uid == accounts.state.active else { return }
      if needsRead || current.status != value.status || current.disabled != value.disabled
        || current.jump != value.jump
      {
        value = current
        issue = needsRead ? nil : "预约状态已更新"
        needsRead = false
        return
      }
      guard let form = current.intent(dynamic: dynamic) else {
        value = current
        return
      }
      let result: [String: Any]
      do {
        result = try await BiliAPI.shared.dynPost(
          "/x/dynamic/feed/reserve/click", form, expectedAccount: uid)
      } catch {
        needsRead = true
        throw error
      }
      guard uid == accounts.state.active else { return }
      if let updated = current.received(result) {
        value = updated
        issue = nil
      } else {
        needsRead = true
        value = try await BiliAPI.shared.viewerReservation(
          dynamic: dynamic, rid: current.id, owner: uid)
        needsRead = false
        issue = nil
      }
    } catch { if uid == accounts.state.active { issue = error.localizedDescription } }
  }
}
