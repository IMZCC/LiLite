import SwiftUI

enum ProfileDestination: Hashable {
  case space(String, String), dynamics(String), relations(String, fans: Bool)
  case history(String), later(String), favorites(String), downloads, accountUses, login
}

struct ProfileAvatar: View {
  var url: URL? = nil
  var size: CGFloat = 64
  /// Avatar frame; drawn 1.75x the avatar around it, like the original's PendantAvatar. It does
  /// not change the layout size.
  var pendant: URL? = nil
  @AppStorage("appearance.decorate") private var decorate = true
  var body: some View {
    SiteThumbnail(url: url) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Circle().fill(.quaternary)
        .overlay { Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(.secondary) }
    }.frame(width: size, height: size).clipShape(Circle())
    .overlay {
      if decorate, let pendant {
        RemoteArtwork(url: pendant) {
          $0.resizable().scaledToFit()
        } placeholder: {
          Color.clear
        }
        .frame(width: size * 1.75, height: size * 1.75)
        .allowsHitTesting(false)
      }
    }
    .accessibilityHidden(true)
  }
}

struct ProfileShortcut: View {
  let title: String, symbol: String, color: Color
  var body: some View {
    VStack(spacing: 8) {
      Image(systemName: symbol).font(.system(size: 19, weight: .semibold))
        .foregroundStyle(.white).frame(width: 42, height: 42)
        .background(color.gradient, in: Circle())
        .accessibilityHidden(true)
      Text(title).font(.footnote.weight(.medium)).foregroundStyle(.primary)
        .lineLimit(1).minimumScaleFactor(0.8)
    }
    .frame(maxWidth: .infinity).padding(.vertical, 14)
    .background(Color(uiColor: .secondarySystemGroupedBackground),
      in: RoundedRectangle(cornerRadius: NativeGlass.panelRadius, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: NativeGlass.panelRadius, style: .continuous))
  }
}

struct ProfileGuestHeader: View {
  var body: some View {
    VStack(spacing: 12) {
      ProfileAvatar(size: 88)
      VStack(spacing: 4) {
        Text("登录哔哩哔哩").font(.title2.weight(.bold)).foregroundStyle(.primary)
        Text("收藏喜欢，继续精彩").font(.subheadline).foregroundStyle(.secondary)
      }
      Text("登录").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        .padding(.horizontal, 28).padding(.vertical, 10)
        .background(Color.accentColor, in: Capsule())
    }.frame(maxWidth: .infinity).padding(.vertical, 8)
  }
}
