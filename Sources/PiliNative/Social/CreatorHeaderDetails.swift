import SwiftUI

struct CreatorHeaderDetails: View {
  let value: CreatorSpaceRecord.HeaderDetails, mid: Int64, name: String?, medals: Bool
  @Environment(\.colorScheme) private var scheme
  var body: some View {
    let banners = value.banners.compactMap { banner -> (CreatorSpaceRecord.HeaderDetails.Banner, GalleryPicture)? in
      guard let url = httpsURL(banner.full) else { return nil }
      return (banner, .init(url))
    }
    if !banners.isEmpty {
      ScrollView(.horizontal) {
        HStack {
          ForEach(banners.indices, id: \.self) { i in
            let banner = banners[i].0
            GalleryLink(banners.map { $0.1 }, index: i) {
              VStack(alignment: .leading) {
                cover(httpsURL(banner.preview) ?? banners[i].1.url, alignment: banner.alignment)
                if let title = banner.title { Text(title).font(.caption) }
                if let text = banner.subtitle { Text(text).font(.caption2) }
              }
            }
          }
        }
      }.accessibilityLabel("空间头图")
    } else if let img = (scheme == .dark ? value.night ?? value.day : value.day).flatMap(httpsURL) {
      GalleryLink([.init(img)], index: 0) { cover(img, alignment: 0) }.accessibilityLabel("查看空间头图")
    }
    if value.muted { Label("该账号封禁中", systemImage: "exclamationmark.circle").foregroundStyle(.secondary) }
    ForEach(value.tags.indices, id: \.self) { i in
      let tag = value.tags[i]
      destination(tag.title ?? "", raw: tag.uri)
    }
    if let promo = value.promo { destination(promo, raw: value.promoURL) }
    if medals, let medal = value.medal {
      NavigationLink { DeferredPage { CreatorMedalWall(mid: mid) } } label: { LabeledContent("佩戴的粉丝勋章", value: medal + (value.medalLevel.map { " · Lv.\($0)" } ?? "")) }
    }
    if !value.charges.isEmpty {
      NavigationLink { DeferredPage { SupporterRanks(mid: mid, name: name, total: value.chargeCount) } } label: {
        crowd("为 TA 充电", faces: value.charges, count: value.chargeCount)
      }
    }
    if !value.guards.isEmpty {
      NavigationLink { DeferredPage { CreatorGuards(mid: mid, name: name, total: value.guardCount) } } label: {
        crowd("加入大航海", faces: value.guards, count: value.guardCount)
      }
    }
  }
  @ViewBuilder private func destination(_ label: String, raw: String?) -> some View {
    if let route = raw.flatMap(SharedLink.parse) { NavigationLink(label) { LinkDestination(item: route) } }
    else if let url = raw.flatMap(httpsURL), url.user == nil, url.password == nil {
      NavigationLink(label) { SitePage(url: url) }
    } else { Text(label) }
  }
  private func cover(_ url: URL, alignment: Double) -> some View {
    GeometryReader { frame in
      SiteThumbnail(url: url) { image in
        image.resizable().scaledToFill().frame(width: frame.size.width, height: frame.size.height,
          alignment: alignment < -0.33 ? .top : alignment > 0.33 ? .bottom : .center).clipped()
      } placeholder: { Color.secondary.opacity(0.12) }
    }.frame(width: 240, height: 110).clipShape(RoundedRectangle(cornerRadius: NativeGlass.cardRadius, style: .continuous))
  }
  private func crowd(_ title: String, faces: [String], count: Int?) -> some View {
    HStack {
      HStack(spacing: -7) {
        ForEach(Array(faces.prefix(3).enumerated()), id: \.offset) { _, f in
          SiteThumbnail(url: httpsURL(f)) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
            .frame(width: 24,height: 24).clipShape(Circle())
        }
      }.accessibilityHidden(true)
      Text((count.map { String($0) + " 人" } ?? "") + title)
    }
  }
}
