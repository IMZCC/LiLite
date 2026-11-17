import SwiftUI

/// The one list row for videos, episodes, favourites, history and similar media across the app:
/// a 16:9 thumbnail (duration, watch progress and an optional corner badge), a two-line title,
/// and up to two quiet secondary lines pinned to the bottom of the thumbnail's height.
struct MediaRow<Accessory: View>: View {
  let cover: URL?
  let title: String
  var badge: String? = nil
  var duration: String? = nil
  var progress: Double? = nil
  var subtitle: String? = nil
  var detail: String? = nil
  var dimmed = false
  var thumbWidth: CGFloat = 140
  /// Source of a zoom transition into the opened page (the cover grows into the player).
  var hero: (id: String, space: Namespace.ID)? = nil
  @ViewBuilder var accessory: () -> Accessory

  var body: some View {
    let thumbHeight = (thumbWidth * 9 / 16).rounded()
    HStack(alignment: .top, spacing: 12) {
      Rectangle().fill(.quaternary).frame(width: thumbWidth, height: thumbHeight)
        .overlay {
          SiteThumbnail(url: cover) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
        }
        .overlay(alignment: .bottomTrailing) {
          if let duration, !duration.isEmpty {
            Text(duration).font(.caption2.monospacedDigit().weight(.semibold)).foregroundStyle(.white)
              .padding(.horizontal, 5).padding(.vertical, 1.5)
              .background(.black.opacity(0.55), in: Capsule()).padding(5)
          }
        }
        .overlay(alignment: .topLeading) {
          if let badge, !badge.isEmpty {
            Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.white)
              .padding(.horizontal, 5).padding(.vertical, 1.5)
              .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
              .padding(5)
          }
        }
        .overlay(alignment: .bottom) {
          if let progress, progress > 0 {
            GeometryReader { g in
              Capsule().fill(Color.accentColor)
                .frame(width: g.size.width * min(1, progress), height: 3)
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
        .modifier(HeroSource(hero: hero))
        .opacity(dimmed ? 0.5 : 1)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.medium)).lineLimit(2)
          .multilineTextAlignment(.leading)
          .foregroundStyle(dimmed ? Color.secondary : Color.primary)
        Spacer(minLength: 4)
        if let subtitle, !subtitle.isEmpty {
          Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        if let detail, !detail.isEmpty {
          Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, minHeight: thumbHeight, alignment: .topLeading)
      accessory()
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
  }
}

extension MediaRow where Accessory == EmptyView {
  init(
    cover: URL?, title: String, badge: String? = nil, duration: String? = nil,
    progress: Double? = nil, subtitle: String? = nil, detail: String? = nil, dimmed: Bool = false,
    thumbWidth: CGFloat = 140, hero: (id: String, space: Namespace.ID)? = nil
  ) {
    self.init(
      cover: cover, title: title, badge: badge, duration: duration, progress: progress,
      subtitle: subtitle, detail: detail, dimmed: dimmed, thumbWidth: thumbWidth, hero: hero) {
      EmptyView()
    }
  }
}
/// Marks a cover as the origin of a zoom navigation transition.
struct HeroSource: ViewModifier {
  let hero: (id: String, space: Namespace.ID)?
  func body(content: Content) -> some View {
    if let hero { content.matchedTransitionSource(id: hero.id, in: hero.space) } else { content }
  }
}
extension View {
  /// Zooms this pushed page out of the cover marked with the same id.
  @ViewBuilder func heroDestination(_ id: String, in space: Namespace.ID, enabled: Bool = true) -> some View {
    if enabled { navigationTransition(.zoom(sourceID: id, in: space)) } else { self }
  }
}

/// Compact "1.2万播放 · 300弹幕" text used by several rows.
enum MediaStats {
  private static let monthDay = dateFormatter("MM-dd")
  private static let yearMonthDay = dateFormatter("yyyy-MM-dd")
  private static func dateFormatter(_ format: String) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.timeZone = .autoupdatingCurrent
    formatter.dateFormat = format
    return formatter
  }
  static func line(views: Int?, danmaku: Int? = nil, extra: [String?] = []) -> String {
    var parts: [String] = []
    if let views { parts.append(views.formatted(.number.notation(.compactName)) + "播放") }
    if let danmaku { parts.append(danmaku.formatted(.number.notation(.compactName)) + "弹幕") }
    parts += extra.compactMap { $0 }.filter { !$0.isEmpty }
    return parts.joined(separator: " · ")
  }
  /// "3小时前" within a day, "昨天", then "11-03" this year and "2024-11-03" before that.
  static func published(_ stamp: Int64?) -> String? {
    guard let stamp, stamp > 0 else { return nil }
    let date = Date(timeIntervalSince1970: TimeInterval(stamp))
    let now = Date()
    let seconds = now.timeIntervalSince(date)
    if seconds < 60 { return "刚刚" }
    if seconds < 3600 { return "\(Int(seconds / 60))分钟前" }
    if seconds < 86_400 { return "\(Int(seconds / 3600))小时前" }
    let cal = Calendar.current
    if cal.isDateInYesterday(date) { return "昨天" }
    let f = cal.isDate(date, equalTo: now, toGranularity: .year) ? monthDay : yearMonthDay
    return f.string(from: date)
  }
}

/// Row for series, films and other poster art: a 3:4 cover with an optional corner badge, a
/// two-line title and up to three quiet lines (the original client's PGC list item).
struct PosterRow<Accessory: View>: View {
  let cover: URL?
  let title: String
  var badge: String? = nil
  var lines: [String] = []
  var accent: String? = nil
  var width: CGFloat = 84
  @ViewBuilder var accessory: () -> Accessory
  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Rectangle().fill(.quaternary).frame(width: width, height: (width * 4 / 3).rounded())
        .overlay {
          SiteThumbnail(url: cover) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
        }
        .overlay(alignment: .topTrailing) {
          if let badge, !badge.isEmpty {
            Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.white)
              .padding(.horizontal, 5).padding(.vertical, 1.5)
              .background(Color.pink, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
              .padding(5)
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: NativeGlass.thumbRadius, style: .continuous))
      VStack(alignment: .leading, spacing: 4) {
        Text(title).font(.subheadline.weight(.medium)).lineLimit(2).multilineTextAlignment(.leading)
        ForEach(lines.filter { !$0.isEmpty }, id: \.self) { line in
          Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        Spacer(minLength: 0)
        if let accent, !accent.isEmpty {
          Text(accent).font(.caption.weight(.medium)).foregroundStyle(.tint).lineLimit(1)
        }
      }
      .frame(maxWidth: .infinity, minHeight: (width * 4 / 3).rounded(), alignment: .topLeading)
      accessory()
    }
    .padding(.vertical, 5)
    .contentShape(Rectangle())
  }
}
extension PosterRow where Accessory == EmptyView {
  init(cover: URL?, title: String, badge: String? = nil, lines: [String] = [], accent: String? = nil,
    width: CGFloat = 84) {
    self.init(cover: cover, title: title, badge: badge, lines: lines, accent: accent, width: width) {
      EmptyView()
    }
  }
}

/// Leaderboard row: rank (gold, silver and bronze for the top three), avatar, name and a quiet
/// trailing note.
struct RankedPersonRow: View {
  let rank: Int
  let avatar: URL?
  let name: String
  var note: String? = nil
  var tag: String? = nil
  var tagColor: Color = .accentColor
  var body: some View {
    HStack(spacing: 12) {
      Text(String(rank)).font(.callout.weight(rank <= 3 ? .heavy : .medium).monospacedDigit())
        .foregroundStyle(Self.medal(rank)).frame(minWidth: 26)
      SiteThumbnail(url: avatar) { $0.resizable().scaledToFill() } placeholder: {
        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.quaternary)
      }
      .frame(width: 40, height: 40).clipShape(Circle())
      .overlay { if rank <= 3 { Circle().stroke(Self.medal(rank), lineWidth: 2).padding(-2) } }
      VStack(alignment: .leading, spacing: 2) {
        Text(name).font(.body.weight(.medium)).lineLimit(1)
        if let note, !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
      }
      Spacer(minLength: 0)
      if let tag, !tag.isEmpty {
        Text(tag).font(.caption2.weight(.semibold)).foregroundStyle(tagColor)
          .padding(.horizontal, 7).padding(.vertical, 2.5)
          .background(tagColor.opacity(0.12), in: Capsule())
      }
    }
    .padding(.vertical, 2).contentShape(Rectangle())
  }
  static func medal(_ rank: Int) -> Color {
    switch rank {
    case 1: Color(red: 0.95, green: 0.70, blue: 0.13)
    case 2: Color(red: 0.62, green: 0.66, blue: 0.72)
    case 3: Color(red: 0.80, green: 0.50, blue: 0.27)
    default: Color.secondary
    }
  }
}
