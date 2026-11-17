import SwiftUI

struct ArchiveSeasonSubscriptionButton: View {
  let item: Int64?, catalog: Int64?, currentBV: String
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    if let uid = accounts.state.active,
      let scope = ArchiveSeasonSubscription(
        item: item, catalog: catalog, bvid: currentBV, owner: uid)
    {
      ButtonContent(scope: scope).id(uid + ":" + currentBV + ":" + String(scope.season))
    }
  }
  private struct ButtonContent: View {
    let scope: ArchiveSeasonSubscription
    @EnvironmentObject private var accounts: AccountContext
    @State private var following: Bool?
    @State private var busy = false
    @State private var issue: String?
    var body: some View {
      VStack(alignment: .leading) {
        if let following {
          Button {
            Task { await change(following) }
          } label: {
            Label(following ? "取消订阅" : "订阅合集", systemImage: following ? "bell.slash" : "bell")
          }.disabled(busy)
        } else if issue == nil {
          ProgressView()
        }
        if let issue {
          Text(issue).piliFont(.caption).foregroundStyle(.secondary)
          if following == nil { Button("重试") { Task { await load() } }.disabled(busy) }
        }
      }.task { await load() }
    }
    @MainActor private func load() async {
      guard !busy, accounts.state.active == scope.owner else { return }
      busy = true
      defer { busy = false }
      do {
        let relation = try await BiliAPI.shared.read(
          "/x/web-interface/archive/relation", ["bvid": scope.bvid],
          expectedAccount: scope.owner, as: ArchiveSeasonSubscription.Relation.self)
        try Task.checkCancellation()
        guard accounts.state.active == scope.owner else { return }
        following = relation.following
        issue = nil
      } catch {
        if !Task.isCancelled && accounts.state.active == scope.owner {
          issue = error.localizedDescription
        }
      }
    }
    @MainActor private func change(_ previous: Bool) async {
      guard !busy, following == previous, accounts.state.active == scope.owner else { return }
      busy = true
      defer { busy = false }
      do {
        let changed = try await scope.toggle(wasFollowing: previous, active: accounts.state.active)
        { path, fields, owner in
          try await BiliAPI.shared.submit(path, fields, expectedAccount: owner)
        }
        guard !Task.isCancelled, accounts.state.active == scope.owner else { return }
        following = changed
        issue = nil
      } catch {
        if !Task.isCancelled && accounts.state.active == scope.owner {
          issue = error.localizedDescription
        }
      }
    }
  }
}
