import SwiftUI

/// Search result rows in the original client's styles: videos as standard media rows, series
/// as posters, users as a profile row with a strip of their latest uploads.
struct SearchHitRow: View {
  let hit: SearchHit
  @State private var cover: GalleryPicture?
  var body: some View {
    Group {
      switch hit.content {
      case .video(let v): VideoLink(video: v)
      case .person(let p): person(p)
      case .link(let target, let c):
        PlainRowLink {
          LinkDestination(item: target)
        } label: {
          label(c, target)
        }.contextMenu { coverAction(c) }
      case .external(let u, let c):
        Link(destination: u) { label(c, nil) }.buttonStyle(.plain).contextMenu { coverAction(c) }
      }
    }.piliSheet(isPresented: Binding(get: { cover != nil }, set: { if !$0 { cover = nil } })) {
      if let cover {
        PiliNavigationStack { NativeGallery([cover]).toolbar { Button("完成") { self.cover = nil } } }
      }
    }
  }
  @ViewBuilder private func person(_ p: SearchHit.Person) -> some View {
    let live = (p.room ?? 0) > 0
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 12) {
        PlainRowLink {
          CreatorSpace(mid: p.creator.mid, name: p.creator.uname ?? "用户空间")
        } label: {
          HStack(spacing: 12) {
            SiteThumbnail(url: httpsURL(p.creator.face ?? "")) { $0.resizable().scaledToFill() } placeholder: {
              Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.quaternary)
            }
            .frame(width: 52, height: 52).clipShape(Circle())
            .overlay { if live { Circle().stroke(Color.pink, lineWidth: 2).padding(-3) } }
            VStack(alignment: .leading, spacing: 3) {
              Text(p.creator.uname ?? "\(p.creator.mid)").font(.body.weight(.semibold)).lineLimit(1)
              if !p.meta.isEmpty { Text(p.meta).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
              if let sign = p.creator.sign, !sign.isEmpty {
                Text(sign).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
            }
            Spacer(minLength: 0)
          }.contentShape(Rectangle())
        }
        if let room = p.room, room > 0 {
          NavigationLink { LivePlayer(id: room, title: p.creator.uname ?? "直播间") } label: {
            Text("直播中").font(.caption.weight(.bold)).foregroundStyle(.white)
              .padding(.horizontal, 9).padding(.vertical, 4)
              .background(Color.pink, in: Capsule())
          }.buttonStyle(.plain)
        }
      }
      if !p.uploads.isEmpty {
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .top, spacing: 10) {
            ForEach(p.uploads.prefix(8)) { v in
              NavigationLink { DetailView(initial: v) } label: {
                VStack(alignment: .leading, spacing: 5) {
                  Rectangle().fill(.quaternary).aspectRatio(16 / 10, contentMode: .fit)
                    .overlay {
                      SiteThumbnail(url: v.cover) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                    }
                    .overlay(alignment: .bottomTrailing) {
                      if let d = v.duration {
                        Text(clockText(Double(d))).font(.caption2.monospacedDigit().weight(.semibold))
                          .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 1.5)
                          .background(.black.opacity(0.5), in: Capsule()).padding(5)
                      }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
                  Text(v.title).font(.caption).lineLimit(2).multilineTextAlignment(.leading)
                }.frame(width: 148)
              }.buttonStyle(.plain)
            }
          }
        }.scrollClipDisabled()
      }
    }
    .padding(.vertical, 4)
  }
  @ViewBuilder private func coverAction(_ c: SearchHit.Card) -> some View {
    if let u = c.cover.flatMap(httpsURL) {
      Button("查看封面", systemImage: "photo") { cover = GalleryPicture(u) }
    }
  }
  @ViewBuilder private func label(_ c: SearchHit.Card, _ target: SharedLink?) -> some View {
    let lines = c.description.components(separatedBy: " · ").filter { !$0.isEmpty }
    if c.cover.flatMap(httpsURL) == nil {
      // Matches, topics and other cards without artwork: a compact text row.
      HStack(spacing: 12) {
        Image(systemName: Self.symbol(target)).font(.title3).foregroundStyle(.tint)
          .frame(width: 40, height: 40)
          .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        VStack(alignment: .leading, spacing: 2) {
          Text(c.title).font(.subheadline.weight(.medium)).lineLimit(2)
          if !c.description.isEmpty {
            Text(c.description).font(.caption).foregroundStyle(.secondary).lineLimit(1)
          }
        }
        Spacer(minLength: 0)
      }.padding(.vertical, 2).contentShape(Rectangle())
    } else {
    switch target {
    case .season?, .episode?:
      PosterRow(
        cover: c.cover.flatMap(httpsURL), title: c.title, lines: Array(lines.prefix(3)), width: 78)
    default:
      MediaRow(
        cover: c.cover.flatMap(httpsURL), title: c.title,
        subtitle: lines.first, detail: lines.dropFirst().joined(separator: " · "))
    }
    }
  }
  private static func symbol(_ target: SharedLink?) -> String {
    switch target {
    case .room?: "dot.radiowaves.left.and.right"
    case .article?: "doc.text"
    case .season?, .episode?: "film"
    case nil: "safari"
    default: "trophy"
    }
  }
}
