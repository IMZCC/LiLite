import PiliWire
import SwiftUI

extension ReplyAuthor {
  init(row: ReplyGateway.Row) {
    let old = row.member
    let new = row.memberV2
    let garb = new.garb
    func either(_ a: String, _ b: String) -> String { a.isEmpty ? b : a }
    let verify = new.hasOfficial ? new.official.verifyType : old.officialVerifyType
    let cardImage = either(garb.cardImage, old.garbCardImage)
    self.init(
      name: either(new.basic.name, old.name), avatar: either(new.basic.face, old.face),
      badge: (new.hasOfficial || row.hasMember) && verify >= 0
        ? .init(type: Int(verify), desc: nil) : nil,
      pendant: either(garb.pendantImage, old.garbPendantImage),
      vipStatus: Int(new.hasVip ? new.vip.status : old.vipStatus),
      vipType: Int(new.hasVip ? new.vip.type : old.vipType),
      card: cardImage.isEmpty
        ? nil
        : .init(
          image: cardImage, number: either(garb.cardNumber, old.garbCardNumber),
          prefix: garb.fanNumPrefix, color: either(garb.cardFanColor, old.garbCardFanColor)))
    if row.hasMember { level = Int(old.level); senior = old.isSeniorMember == 1 }
    if old.fansMedalLevel > 0 && !old.fansMedalName.isEmpty {
      medal = .init(name: old.fansMedalName, level: old.fansMedalLevel,
        background: old.fansMedalColor, foreground: old.fansMedalColorName)
    }
  }
}

/// Avatar with the optional decoration frame (pendant).
struct ReplyAvatar: View {
  let member: ReplyAuthor?
  var size: CGFloat = 32
  @AppStorage("appearance.decorate") private var decorate = true
  var body: some View {
    ZStack {
      let frame = decorate ? member?.pendant.flatMap(httpsURL) : nil
      SiteThumbnail(url: member?.avatar.flatMap(httpsURL)) {
        $0.resizable().scaledToFill()
      } placeholder: {
        Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
      }.frame(width: frame == nil ? size : size * 0.84, height: frame == nil ? size : size * 0.84)
        .clipShape(Circle())
      if let frame {
        RemoteArtwork(url: frame) {
          $0.resizable().scaledToFit()
        } placeholder: {
          Color.clear
        }
        .frame(width: size * 1.34, height: size * 1.34).allowsHitTesting(false)
      }
      // Drawn over the pendant at the avatar's own bottom-right corner, as PendantAvatar does.
      let d = frame == nil ? size : size * 0.84
      let side = max(12, size * 0.4)
      badge(side).offset(x: (d - side) / 2 + 1, y: (d - side) / 2 + 1).allowsHitTesting(false)
    }.frame(width: size * 1.18, height: size * 1.25).accessibilityHidden(true)
  }
  /// The original's corner badge: official verification wins, otherwise 大会员.
  @ViewBuilder private func badge(_ side: CGFloat) -> some View {
    let official = member?.official_verify?.type ?? -1
    if official == 0 || official == 1 {
      Image(systemName: "bolt.circle.fill").resizable().scaledToFit()
        .foregroundStyle(.white, official == 1 ? Color(red: 0.25, green: 0.77, blue: 1) : Color(red: 1, green: 0.7, blue: 0.1))
        .frame(width: side, height: side)
        .background(Circle().fill(Color(uiColor: .systemBackground)).padding(-1))
    } else if (member?.vipStatus ?? 0) > 0 {
      Text("大").font(.system(size: side * 0.62, weight: .heavy)).foregroundStyle(.white)
        .frame(width: side, height: side)
        .background(Circle().fill(Color(red: 0.98, green: 0.45, blue: 0.6)))
        .background(Circle().fill(Color(uiColor: .systemBackground)).padding(-1))
    }
  }
}

struct ReplyAuthorLabel: View {
  let member: ReplyAuthor?
  var isOwner = false
  var showsAvatar = true
  @AppStorage("live.medal") private var showMedal = true
  var body: some View {
    HStack(spacing: 6) {
      if showsAvatar { ReplyAvatar(member: member) }
      Text(member?.uname ?? "用户").lineLimit(1).foregroundStyle(
        member?.vipStatus == 1 && member?.vipType == 2 ? Color.pink : Color.primary)
      if let level = member?.level {
        UserLevelBadge(level: level, height: 10, hardcore: member?.senior == true)
      }
      // Name, level, then the medal, as in the original. Verification and 大会员 are the
      // avatar's corner badge (PendantAvatar), not marks beside the name.
      if showMedal && !isOwner, let m = member?.medal {
        let (bg, fg) = Self.medalColors(m)
        // The original's medal: small rounded plate, name then bold level.
        (Text(m.name) + Text(" " + String(m.level)).bold())
          .font(.system(size: 10)).lineLimit(1).fixedSize()
          .foregroundStyle(fg)
          .padding(.horizontal, 6).padding(.vertical, 2.5)
          .background(bg, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
          .accessibilityLabel(m.name + "粉丝勋章 " + String(m.level) + " 级")
      }
    }.accessibilityElement(children: .combine)
  }
  private static func rgb(_ v: Int64) -> (Double, Double, Double) {
    let n = UInt32(truncatingIfNeeded: v)
    return (Double(n >> 16 & 255) / 255, Double(n >> 8 & 255) / 255, Double(n & 255) / 255)
  }
  private static func luminance(_ c: (Double, Double, Double)) -> Double {
    0.299 * c.0 + 0.587 * c.1 + 0.114 * c.2
  }
  /// The server sometimes sends the same colour for the plate and the name (newer medals), which
  /// draws an empty pill; fall back to white or dark text, whichever reads on the plate.
  private static func medalColors(_ m: ReplyAuthor.Medal) -> (Color, Color) {
    let bg = rgb(m.background), fg = rgb(m.foreground)
    let plate = Color(red: bg.0, green: bg.1, blue: bg.2)
    if abs(luminance(bg) - luminance(fg)) >= 0.3 {
      return (plate, Color(red: fg.0, green: fg.1, blue: fg.2))
    }
    return (plate, luminance(bg) < 0.62 ? .white : Color(white: 0.15))
  }
}

struct ReplyCardBadge: View {
  let card: ReplyAuthor.Card?
  @AppStorage("appearance.decorate") private var decorate = true
  private func color(_ raw: String) -> Color {
    let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
    guard hex.count == 6, let n = UInt32(hex, radix: 16) else { return .primary }
    return Color(
      red: Double(n >> 16) / 255, green: Double(n >> 8 & 255) / 255, blue: Double(n & 255) / 255)
  }
  var body: some View {
    if decorate, let card, let url = httpsURL(card.image) {
      // As in the original: the card at 38pt tall in the row's top-right corner at its natural
      // width, the fan number at its right edge where the card art leaves room for it.
      RemoteArtwork(url: url) { phase in
        if let image = phase.image {
          image.resizable().scaledToFit().frame(height: 38)
            .overlay(alignment: .trailing) {
              if !card.number.isEmpty {
                Text(card.prefix.isEmpty ? card.number : card.prefix + "\n" + card.number)
                  .font(.system(size: 8, weight: .medium, design: .monospaced))
                  .multilineTextAlignment(.center).lineSpacing(-1)
                  .foregroundStyle(color(card.color))
              }
            }
        }
      }
      .frame(maxWidth: 120, maxHeight: 38, alignment: .trailing).accessibilityHidden(card.number.isEmpty).accessibilityLabel(
        [card.prefix, card.number].filter { !$0.isEmpty }.joined(separator: " "))
    }
  }
}
