import SwiftUI

/// An anchored, read-only video list opened from an official /playlist/pl… sharing link.
struct SharedMediaPlaylist: View {
  let id: Int64, bvid: String
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    if id > 0, let av = ArchiveNumber.av(bvid), let normalized = ArchiveNumber.bv(av) {
      let owners = CreatorQueueOwners(accounts.state)
      LibraryPlaylist(
        kind: .shared(id, owners), uid: owners.main, query: "", order: .mtime, viewed: 0,
        ascending: false,
        start: .init(rowID: normalized), allowChanges: false, embedded: true
      )
      .id(String(id) + ":" + normalized)
    } else {
      ContentUnavailableView("播放列表地址无效", systemImage: "list.bullet.rectangle")
    }
  }
}
