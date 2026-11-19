import SwiftUI

enum HomeCardStyle {
  /// Off by default: like the official client every recommendation is a double-column card.
  static let featuredKey = "feed.featuredFirst"
  /// The official home card's cover is 4:3, cropped from the 16:9 artwork.
  static let coverAspect: CGFloat = 4 / 3
  static let radius: CGFloat = NativeGlass.thumbRadius
  /// Grid spacing between official cards: tight, so the covers carry the page.
  static let gap: Double = 8
  /// The orange the official client uses for "已关注" and reason badges.
  static let accent = Color(red: 0.98, green: 0.42, blue: 0.27)
  /// Counts the way the official client prints them: 7398, 8.1万, 1.2亿.
  static func count(_ n: Int) -> String {
    func short(_ v: Double) -> String {
      let s = String(format: "%.1f", v)
      return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
    if n >= 100_000_000 { return short(Double(n) / 100_000_000) + "亿" }
    if n >= 10_000 { return short(Double(n) / 10_000) + "万" }
    return String(max(0, n))
  }
}

/// The official client's home card: a cover with play and danmaku counts and the duration over a
/// shade, a two-line title, then a reason badge, a followed mark or the uploader. The trailing
/// "more" button is laid over the card by its owner, so this view leaves room for it.
struct HomeVideoCard: View {
  let video: Video
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Color.clear.aspectRatio(HomeCardStyle.coverAspect, contentMode: .fit)
        .overlay {
          SiteThumbnail(url: video.cover) { img in
            img.resizable().scaledToFill()
          } placeholder: {
            Color(uiColor: .quaternarySystemFill)
          }
        }
        .overlay(alignment: .bottom) { stats }
        .clipped()
      VStack(alignment: .leading, spacing: 6) {
        Text(video.title).font(.subheadline).foregroundStyle(.primary)
          .lineLimit(2, reservesSpace: true).multilineTextAlignment(.leading)
        footer.font(.caption).frame(height: 20, alignment: .leading)
          .padding(.trailing, 26)
      }
      .padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 7)
    }
    .background(Color(uiColor: .secondarySystemGroupedBackground))
    .clipShape(RoundedRectangle(cornerRadius: HomeCardStyle.radius, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: HomeCardStyle.radius, style: .continuous))
  }
  private var stats: some View {
    HStack(spacing: 10) {
      if let views = video.stat?.view {
        HStack(spacing: 3) {
          Image(systemName: "play.rectangle")
          Text(HomeCardStyle.count(views))
        }
      }
      if let danmaku = video.stat?.danmaku {
        HStack(spacing: 3) {
          Image(systemName: "list.bullet.rectangle")
          Text(HomeCardStyle.count(danmaku))
        }
      }
      Spacer(minLength: 4)
      if let d = video.duration, d > 0 { Text(clockText(Double(d))) }
    }
    .font(.caption2.monospacedDigit().weight(.medium)).foregroundStyle(.white)
    .lineLimit(1)
    .padding(.horizontal, 8).padding(.top, 18).padding(.bottom, 6)
    .background(
      LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
  }
  @ViewBuilder private var footer: some View {
    let name = video.owner?.name.flatMap { $0.isEmpty ? nil : $0 }
    if video.is_followed == 1 {
      HStack(spacing: 3) {
        Image(systemName: "checkmark.circle.fill")
        Text("已关注")
        if let name { Text(name).foregroundStyle(.secondary) }
      }.foregroundStyle(HomeCardStyle.accent).lineLimit(1)
    } else if let reason = video.recommendationReason, !reason.isEmpty {
      Text(reason).lineLimit(1).foregroundStyle(HomeCardStyle.accent)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(
          HomeCardStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    } else if let name {
      HStack(spacing: 4) {
        Text("UP").font(.system(size: 8, weight: .bold))
          .padding(.horizontal, 2).padding(.vertical, 1)
          .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(lineWidth: 1))
        Text(name).lineLimit(1)
      }.foregroundStyle(.secondary)
    }
  }
}
