import SwiftUI

extension VideoCollection.Part {
  func ordered(_ reversed: Set<Int64>) -> [VideoCollection.Entry] {
    let rows = episodes ?? []
    return reversed.contains(id) ? Array(rows.reversed()) : rows
  }
}
extension VideoCollection.Entry {
  func playable(by owner: String?) -> Video? {
    guard let b = bvid, !b.isEmpty else { return nil }
    return .preview(
      id: b, title: title ?? b, cover: arc?.pic ?? "", author: owner, duration: arc?.duration)
  }
}
struct ArchiveCollectionPanel: View {
  let catalog: VideoCollection, current: String, currentCID:Int64,owner: String?, canReverse: Bool
  var subscriptionID: Int64? = nil
  @Binding var reversed: Set<Int64>
  let play: (Video,Int64?) -> Void
  @AppStorage("play.reverseFirst") private var jump = true
  @Environment(\.dismiss) private var dismiss
  var pictures: [GalleryPicture] {
    let urls =
      [catalog.cover]
      + (catalog.sections ?? []).flatMap { $0.ordered(reversed).map { $0.arc?.pic } }
    var seen = Set<URL>()
    return urls.compactMap { $0.flatMap(httpsURL) }.filter { seen.insert($0).inserted }.map {
      .init($0)
    }
  }
  var body: some View {
    let photos = pictures
    PiliNavigationStack {
      List {
        ArchiveSeasonSubscriptionButton(item: subscriptionID, catalog: catalog.id, currentBV: current)
        if !photos.isEmpty {
          GalleryLink(photos, index: 0) { Label("合集封面", systemImage: "photo.stack") }
        }
        ForEach(catalog.sections ?? []) { section in
          Section {
            ForEach(section.ordered(reversed)) { entry in
              if let video = entry.playable(by: owner) {
                Button {
                  if current != video.bvid || (entry.cid != nil && entry.cid != currentCID){play(video,entry.cid ?? entry.page?.cid)}
                  dismiss()
                } label: {
                  MediaRow(cover: video.cover, title: video.title, badge: entry.badge,
                    duration: video.duration.map { clockText(Double($0)) }, thumbWidth: 120) {
                    if current == video.bvid {
                      Image(systemName: "waveform").foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                        .accessibilityLabel("正在播放")
                    }
                  }
                }.buttonStyle(.plain).archiveCover(video)
                // Parts sit under their episode as a horizontal strip, like the original's PagePanel.
                if let parts=entry.pages,parts.count>1{
                  ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                      ForEach(parts){part in
                        let on = current==video.bvid && currentCID==part.cid
                        Button{play(video,part.cid);dismiss()}label:{
                          Text("P\(part.page) "+part.part).font(.footnote).lineLimit(1)
                            .foregroundStyle(on ? Color.accentColor : Color.primary)
                            .padding(.horizontal, 12).padding(.vertical, 8).frame(maxWidth: 160)
                            .background(on ? Color.accentColor.opacity(0.12) : Color(uiColor: .tertiarySystemFill),
                              in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }.buttonStyle(.plain)
                      }
                    }
                  }.listRowSeparator(.hidden)
                }
              }
            }
          } header: {
            HStack {
              Text(section.title ?? "合集")
              Spacer()
              if canReverse, (section.episodes?.count ?? 0) > 1 {
                Button {
                  if reversed.contains(section.id) {
                    reversed.remove(section.id)
                  } else {
                    reversed.insert(section.id)
                  }
                  if jump,
                    let first = section.ordered(reversed).compactMap({ $0.playable(by: owner) })
                      .first, first.bvid != current
                  {
                    play(first,section.ordered(reversed).first(where:{$0.bvid==first.bvid})?.cid)
                    dismiss()
                  }
                } label: {
                  Image(systemName: reversed.contains(section.id) ? "arrow.up.arrow.down.circle.fill" : "arrow.up.arrow.down.circle")
                    .font(.system(size: 18))
                }.accessibilityLabel(reversed.contains(section.id) ? "顺序播放" : "倒序播放")
              }
            }
          }
        }
      }.modifier(ReplyEdgeDismiss()).navigationTitle(catalog.title ?? "视频合集").toolbar { Button("完成") { dismiss() } }
    }
  }
}
