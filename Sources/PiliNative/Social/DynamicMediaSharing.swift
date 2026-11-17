import SwiftUI

extension DynamicShareResource {
  static func archive(_ v: Video) -> Self? {
    guard let aid = v.aid ?? ArchiveNumber.av(v.bvid), aid > 0 else { return nil }
    return .init(
      id: aid, type: 8, title: v.title, commentOID: aid, commentType: 1,
      author: v.owner?.name, cover: v.pic, mentionID: v.owner?.mid)
  }
  static func song(_ s: AudioSong) -> Self? {
    guard s.id > 0 else { return nil }
    return .init(id: s.id, type: 256, title: s.title, author: s.author, cover: s.cover)
  }
  static func listening(_ t: ListenTrack) -> Self? {
    if let song = t.songID, song > 0 {
      return .init(id: song, type: 256, title: t.title, author: t.artist, cover: t.cover)
    }
    guard let aid = ArchiveNumber.av(t.bvid), aid > 0 else { return nil }
    return .init(
      id: aid, type: 8, title: t.archiveTitle ?? t.title, author: t.artist, cover: t.cover)
  }
  static func episode(_ e: SeasonInfo.Episode, category: Int?, parent: String?) -> Self? {
    guard let type = seasonKind(category), e.id > 0 else { return nil }
    let title =
      e.share_copy.flatMap { $0.isEmpty ? nil : $0 }
      ?? [parent, e.label].compactMap { $0 }.joined(separator: " · ")
    let aid = e.aid ?? ArchiveNumber.av(e.bvid)
    return .init(
      id: e.id, type: type, title: title, commentOID: aid, commentType: aid == nil ? nil : 1,
      cover: e.cover)
  }
}
struct MediaMomentSelection: Identifiable {
  let id = UUID()
  let resource: DynamicShareResource, owner: String
}
struct MediaMomentButton: View {
  let resource: DynamicShareResource?
  @Binding var selection: MediaMomentSelection?
  @EnvironmentObject private var accounts: AccountContext
  var body: some View {
    if let resource, let uid = accounts.state.active {
      Button {
        selection = .init(resource: resource, owner: uid)
      } label: {
        Label("分享至动态", systemImage: "square.and.pencil")
      }
    }
  }
}
private struct MediaMomentPresentation: ViewModifier {
  @Binding var selection: MediaMomentSelection?
  @EnvironmentObject private var accounts: AccountContext
  func body(content: Content) -> some View {
    content.piliSheet(item: $selection) { s in
      if s.owner == accounts.state.active { DynamicComposer(resource: s.resource) {} }
    }.onChange(of: accounts.state.active) { _, _ in selection = nil }
  }
}
extension View {
  func mediaMomentSheet(_ selection: Binding<MediaMomentSelection?>) -> some View {
    modifier(MediaMomentPresentation(selection: selection))
  }
}
