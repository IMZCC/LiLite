import SwiftUI
import UIKit

/// The official client's video intro (theseus2, the Compose page it shares between Android and
/// iOS), from its decompiled source: OwnerContent, StaffsContent, UgcHeadlineComponent,
/// KingPositionContent, UgcSeasonContent and RelateSharedCardContent. Its dp and sp are drawn
/// scaled with the screen's width against a 411 dp design (about 1.05× on a 430 pt phone, which
/// is what its screenshots measure), so every size here goes through `d` and `font`.
@MainActor enum OfficialIntro {
  static let scale: CGFloat = {
    let width = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }
      .map { min($0.width, $0.height) }.first ?? 411
    return min(1.1, max(0.92, width / 411))
  }()
  /// A dp length, to the half point.
  static func d(_ dp: CGFloat) -> CGFloat { (dp * scale * 2).rounded() / 2 }
  static func font(_ sp: CGFloat, _ weight: Font.Weight = .regular) -> Font {
    .system(size: sp * scale, weight: weight)
  }
  // The theme's greys (day / night).
  static let ga1 = tone(0xF6F7F8, 0x1E2022)
  static let ga2 = tone(0xE3E5E7, 0x2F3134)
  static let ga5 = tone(0x9499A0, 0x757A81)
  static let ga7 = tone(0x61666D, 0xA2A7AE)
  static let text1 = tone(0x18191C, 0xE7E9EB)
  /// A 大会员's name (authorNameColor).
  static let vipName = tone(0xFB7299, 0xD44E7D)
  /// A member of the team with 大会员 (StaffCompactItem).
  static let vipStaff = tone(0xFF6699, 0xD44E7D)
  private static func tone(_ day: UInt32, _ night: UInt32) -> Color {
    Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? rgb(night) : rgb(day) })
  }
  private static func rgb(_ v: UInt32) -> UIColor {
    UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
      blue: CGFloat(v & 0xFF) / 255, alpha: 1)
  }
}

/// Whether the intro is open. An observed object rather than the page's `@State`: the intro is
/// drawn in the tab pager's own hosting view (NativePager), which is handed a whole new root
/// whenever the page's state changes, and the `withAnimation` around such a change never reached
/// it — the intro opened in one jump. Read inside the intro, a change redraws it in place, in the
/// tap's transaction.
@Observable final class IntroExpansion {
  var open = false
}

extension OfficialIntro {
  /// The intro opening and closing: a spring on a height, so a tap mid-way turns it round from
  /// wherever it has got to.
  static let expand: Animation = {
    // PILI_ANIMATION_SPEED (debug launches only) slows it with the rest of the app.
    let speed = ProcessInfo.processInfo.environment["PILI_ANIMATION_SPEED"].flatMap(Double.init)
      .map { min(1, max(0.05, $0)) } ?? 1
    return .spring(response: 0.4 / speed, dampingFraction: 0.9)
  }()
}

/// Content that opens by growing its visible height, clipped, rather than by being inserted.
/// The height is an animated value, so the reveal can be reversed mid-way; an inserted view's
/// transition could not, and the rows under it jumped.
struct HeightReveal<Content: View>: View {
  let open: Bool
  @ViewBuilder let content: () -> Content
  @State private var full: CGFloat = 0
  var body: some View {
    content()
      .fixedSize(horizontal: false, vertical: true)
      .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
        // Content that grows while open (tags arriving) eases to its new height too.
        withAnimation(open && full > 0 ? OfficialIntro.expand : nil) { full = height }
      }
      .frame(height: open ? full : 0, alignment: .top)
      .clipped()
      .opacity(open ? 1 : 0)
      .allowsHitTesting(open)
      .accessibilityHidden(!open)
  }
}

/// Where tapping a creator goes: the page's side panel, or their space.
enum IntroCreatorOpen {
  case panel(() -> Void)
  case space
}

/// A tappable creator: the side panel, or a link to their space.
private struct CreatorTap<Label: View>: View {
  let mid: Int64, name: String
  let open: IntroCreatorOpen
  @ViewBuilder let label: () -> Label
  var body: some View {
    switch open {
    case .panel(let show):
      Button {
        TouchFeedback.light()
        show()
      } label: { label() }.buttonStyle(.plain)
    case .space:
      LazyLink { CreatorSpace(mid: mid, name: name) } label: { label() }
        .buttonStyle(.plain).piliTapFeedback()
    }
  }
}

// MARK: - UP 主

/// OwnerCard: a 54 dp row — the avatar centred in a 54 dp box, then the name (13 sp, pink for
/// 大会员) 11 dp from the top over "粉丝" and "视频" (10 sp, Ga5, 10 dp apart), each on an 18 dp
/// line, and the follow button 12 dp from the edge.
struct IntroOwnerRow: View {
  let mid: Int64?, name: String, avatar: URL?
  let open: IntroCreatorOpen
  var follows = true
  @EnvironmentObject private var accounts: AccountContext
  @State private var card: CreatorCardSummary?
  var body: some View {
    let d = OfficialIntro.d
    HStack(spacing: 0) {
      if let mid {
        CreatorTap(mid: mid, name: name, open: open) { identity }
      } else {
        identity
      }
      Spacer(minLength: d(12))
      if follows, let mid {
        CreatorQuickRelation(mid: mid, style: .capsule).padding(.trailing, d(12))
      }
    }
    .frame(height: d(54))
    .task(id: mid) {
      guard let mid, mid > 0 else { card = nil; return }
      card = CreatorCardSummary.cached[mid]
      guard card == nil else { return }
      if let loaded = try? await CreatorCardSummary.load(mid, owner: accounts.state.active), !Task.isCancelled {
        withAnimation(.easeOut(duration: 0.2)) { card = loaded }
      }
    }
  }
  private var identity: some View {
    let d = OfficialIntro.d
    return HStack(spacing: 0) {
      ProfileAvatar(url: avatar, size: d(30)).frame(width: d(54), height: d(54))
      VStack(alignment: .leading, spacing: 0) {
        Text(name).font(OfficialIntro.font(13)).lineLimit(1)
          .foregroundStyle(card?.annualVIP == true ? OfficialIntro.vipName : OfficialIntro.text1)
          .frame(height: d(18), alignment: .leading)
        HStack(spacing: d(10)) {
          if let fans = card?.fans { Text(fans.formatted(.number.notation(.compactName)) + "粉丝") }
          if let videos = card?.videos { Text(videos.formatted(.number.notation(.compactName)) + "视频") }
        }
        .font(OfficialIntro.font(10)).foregroundStyle(OfficialIntro.ga5).monospacedDigit().lineLimit(1)
        .frame(height: d(18), alignment: .leading)
      }
      .padding(.top, d(11)).frame(height: d(54), alignment: .top)
    }
    .contentShape(Rectangle())
  }
}

// MARK: - 创作团队

/// StaffsContent: a 32 dp header ("创作团队", 14 sp bold; "共 N 位 ›", 12 sp Ga5) over a 50 dp
/// row of members — a 30 dp avatar ringed in Ga2, the name (13 sp, pink for 大会员) over the role
/// (10 sp Ga5), then the 30 × 22 follow pill.
struct IntroStaffs: View {
  let staff: [VideoStaff]
  let open: (VideoStaff) -> IntroCreatorOpen
  @State private var showsAll = false
  var body: some View {
    let d = OfficialIntro.d
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 0) {
        Text("创作团队").font(OfficialIntro.font(14, .bold)).foregroundStyle(OfficialIntro.text1)
        Spacer(minLength: d(8))
        Button {
          TouchFeedback.light()
          showsAll = true
        } label: {
          HStack(spacing: d(2)) {
            Text("共\(staff.count)位").font(OfficialIntro.font(12))
            Image(systemName: "chevron.right").font(.system(size: d(10), weight: .semibold))
          }
          .foregroundStyle(OfficialIntro.ga5)
          .frame(height: d(32)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
      }
      .padding(.horizontal, d(12)).frame(height: d(32))
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: d(24)) {
          ForEach(staff.filter { $0.mid > 0 }) { member in member.compact(open: open(member)) }
        }
        .padding(.horizontal, d(12))
      }
      .frame(height: d(50))
    }
    .piliSheet(isPresented: $showsAll) {
      PiliNavigationStack {
        List(staff.filter { $0.mid > 0 }) { member in
          LazyLink { CreatorSpace(mid: member.mid, name: member.name ?? "创作者") } label: {
            HStack(spacing: 12) {
              member.avatar(size: 40)
              VStack(alignment: .leading, spacing: 2) {
                Text(member.name ?? "创作者").font(.body).lineLimit(1)
                  .foregroundStyle(member.isVIP ? OfficialIntro.vipStaff : OfficialIntro.text1)
                if let role = member.title, !role.isEmpty {
                  Text(role).font(.footnote).foregroundStyle(OfficialIntro.ga5)
                }
              }
              Spacer(minLength: 8)
              CreatorQuickRelation(mid: member.mid, style: .capsule)
            }
          }
        }
        .listStyle(.plain)
        .navigationTitle("创作团队").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { showsAll = false } } }
      }
      .presentationDetents([.medium, .large])
    }
  }
}

@MainActor private extension VideoStaff {
  var isVIP: Bool { vip?.status == 1 && (vip?.type ?? 0) > 0 }
  func avatar(size: CGFloat) -> some View {
    ProfileAvatar(url: face.flatMap(httpsURL), size: size)
      .overlay { Circle().strokeBorder(OfficialIntro.ga2, lineWidth: OfficialIntro.d(1)) }
  }
  /// StaffCompactItem.
  func compact(open: IntroCreatorOpen) -> some View {
    let d = OfficialIntro.d
    return HStack(spacing: 0) {
      CreatorTap(mid: mid, name: name ?? "创作者", open: open) {
        HStack(spacing: 0) {
          avatar(size: d(30))
          VStack(alignment: .leading, spacing: 0) {
            Text(name ?? "创作者").font(OfficialIntro.font(13)).lineLimit(1)
              .foregroundStyle(isVIP ? OfficialIntro.vipStaff : OfficialIntro.text1)
              .frame(height: d(18), alignment: .leading)
            if let title, !title.isEmpty {
              Text(title).font(OfficialIntro.font(10)).foregroundStyle(OfficialIntro.ga5).lineLimit(1)
                .frame(height: d(14), alignment: .leading)
            }
          }
          .padding(.leading, d(6)).padding(.trailing, d(8))
        }
        .contentShape(Rectangle())
      }
      CreatorQuickRelation(mid: mid, style: .pill)
    }
    .frame(height: d(50))
  }
}

// MARK: - 合集

/// UgcSimpleSeasonRow: a 36 dp bar (Ga1, 4 dp corners, 6 dp above and below) with the
/// collection's name (14 sp, Ga10), the playing wave, "2/2" (12 sp Ga5) and a chevron.
struct IntroSeasonRow: View {
  let title: String
  let position: String?
  let open: () -> Void
  var body: some View {
    let d = OfficialIntro.d
    Button {
      TouchFeedback.light()
      open()
    } label: {
      HStack(spacing: 0) {
        Text("合集 · " + title).font(OfficialIntro.font(14)).foregroundStyle(OfficialIntro.text1).lineLimit(1)
          .frame(maxWidth: .infinity, alignment: .leading)
        Image(systemName: "waveform").font(.system(size: d(11), weight: .semibold))
          .symbolEffect(.variableColor.iterative, options: .repeating)
          .frame(width: d(38), height: d(14), alignment: .trailing)
        if let position {
          Text(position).font(OfficialIntro.font(12)).monospacedDigit().padding(.leading, d(4))
        }
        Image(systemName: "chevron.right").font(.system(size: d(11), weight: .semibold))
          .frame(width: d(16), height: d(16))
      }
      .foregroundStyle(OfficialIntro.ga5)
      .padding(.leading, d(9)).padding(.trailing, d(5))
      .frame(height: d(36))
      .background(OfficialIntro.ga1, in: RoundedRectangle(cornerRadius: d(4), style: .continuous))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.horizontal, d(12)).padding(.vertical, d(6))
    .accessibilityLabel("合集 " + title + (position.map { "，第 " + $0 } ?? ""))
  }
}

// MARK: - 相关推荐

/// RelateSharedGenericCard: a 128 × 72 dp cover (the length in a 16 dp translucent badge) beside
/// the title (14 sp, two lines), the author after the UP glyph and the counts (12 sp Ga5), and
/// the "⋮" button; 12 dp margins, a hairline under each card.
struct IntroRelateRow: View {
  let video: Video
  var body: some View {
    let d = OfficialIntro.d
    let width = d(128), height = d(72)
    HStack(alignment: .top, spacing: d(8)) {
      Rectangle().fill(OfficialIntro.ga1)
        .overlay { SiteThumbnail(url: video.cover) { $0.resizable().scaledToFill() } placeholder: { Color.clear } }
        .frame(width: width, height: height)
        .overlay(alignment: .bottomTrailing) {
          if let length = video.duration, length > 0 {
            Text(clockText(Double(length))).font(OfficialIntro.font(10)).monospacedDigit().foregroundStyle(.white)
              .padding(.horizontal, d(3)).frame(height: d(16))
              .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: d(2), style: .continuous))
              .padding(d(5))
          }
        }
        .clipShape(RoundedRectangle(cornerRadius: d(4), style: .continuous))
        .cardZoomCover(radius: d(4))
      VStack(alignment: .leading, spacing: 0) {
        Text(video.title).font(OfficialIntro.font(14)).foregroundStyle(OfficialIntro.text1)
          .lineLimit(2).multilineTextAlignment(.leading)
        Spacer(minLength: d(2))
        if let author = video.owner?.name, !author.isEmpty {
          HStack(spacing: d(2)) {
            Image(systemName: "person").font(.system(size: d(10), weight: .medium)).frame(width: d(16), height: d(16))
            Text(author).lineLimit(1)
          }
          .frame(height: d(17))
        }
        HStack(spacing: d(10)) {
          if let views = video.stat?.view { stat("play.rectangle", views) }
          if let danmaku = video.stat?.danmaku { stat("list.bullet.rectangle", danmaku) }
          Spacer(minLength: 0)
        }
        .frame(height: d(17))
      }
      .font(OfficialIntro.font(12)).foregroundStyle(OfficialIntro.ga5)
      .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .topLeading)
    }
    .padding(.horizontal, d(12)).padding(.vertical, d(10))
    .overlay(alignment: .bottom) {
      Rectangle().fill(OfficialIntro.ga2).frame(height: 0.5).padding(.horizontal, d(12))
    }
    .contentShape(Rectangle())
  }
  private func stat(_ symbol: String, _ n: Int) -> some View {
    HStack(spacing: OfficialIntro.d(2)) {
      Image(systemName: symbol).font(.system(size: OfficialIntro.d(11)))
      Text(n.formatted(.number.notation(.compactName))).monospacedDigit()
    }
  }
  /// RelateSharedMoreButton: 40 × 28 at the card's bottom right. Laid over the card by the list,
  /// outside its link, so a tap on it never opens the video.
  static func more(_ video: Video) -> some View {
    let d = OfficialIntro.d
    return ArchiveCoverMoreButton(video: video) {
      Image(systemName: "ellipsis").rotationEffect(.degrees(90))
        .font(.system(size: d(12), weight: .semibold)).foregroundStyle(OfficialIntro.ga5)
        .frame(width: d(40), height: d(28)).contentShape(Rectangle())
    }
    .padding(.bottom, d(8))
  }
}
