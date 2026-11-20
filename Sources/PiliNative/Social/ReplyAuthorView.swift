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
          prefix: garb.fanNumPrefix, color: either(garb.cardFanColor, old.garbCardFanColor),
          gradient: garb.hasFanNumColorFormat
            ? .init(start: garb.fanNumColorFormat.startPoint, end: garb.fanNumColorFormat.endPoint,
              colors: garb.fanNumColorFormat.colors, stops: garb.fanNumColorFormat.gradients)
            : nil))
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
  /// The name's colour for members without 年度大会员 (grey in comment rows, as officially).
  var plainName: Color = .primary
  @AppStorage("live.medal") private var showMedal = true
  var body: some View {
    HStack(spacing: 6) {
      if showsAvatar { ReplyAvatar(member: member) }
      Text(member?.uname ?? "用户").lineLimit(1).foregroundStyle(
        member?.vipStatus == 1 && member?.vipType == 2 ? Color.pink : plainName)
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
  /// The official comment layout (its `DecorationOverlay`): the card in a box at the top-right of
  /// the author row, laid over it, instead of a small badge in a row of its own.
  var overlay = false
  /// Inline badge: 38pt tall at its natural width, up to this wide.
  static let height: CGFloat = 38, width: CGFloat = 130
  /// The official box: the card is a 6:1 strip with its art on the right, drawn across 288 × 48.
  static let strip = CGSize(width: 288, height: 48)
  /// The art's part of the strip, on its right (the official tap target): the name keeps clear.
  static let art: CGFloat = 111
  /// Narrower author rows show no card, as in the official client.
  static let minimumRow: CGFloat = 244
  @AppStorage("appearance.decorate") private var decorate = true
  /// #RRGGBB or #AARRGGBB.
  private static func color(_ raw: String) -> Color? {
    let hex = raw.hasPrefix("#") ? String(raw.dropFirst()) : raw
    guard hex.count == 6 || hex.count == 8, let n = UInt32(hex, radix: 16) else { return nil }
    let alpha = hex.count == 8 ? Double(n >> 24) / 255 : 1
    return Color(
      red: Double(n >> 16 & 255) / 255, green: Double(n >> 8 & 255) / 255, blue: Double(n & 255) / 255,
      opacity: alpha)
  }
  private func color(_ raw: String) -> Color { Self.color(raw) ?? .primary }
  var body: some View {
    if overlay {
      if decorate, let card, let url = httpsURL(card.image) {
        ViewThatFits(in: .horizontal) {
          Color.clear.frame(width: Self.minimumRow, height: 0)
            .overlay(alignment: .topTrailing) { stripView(card, url) }
          Color.clear.frame(width: 0, height: 0)
        }
      }
    } else {
      inline
    }
  }
  /// As the official client draws it: the strip filling the box, and the prefix over the number
  /// in the digital face at 7pt on 7pt lines, left-aligned, centred on the right 20pt in.
  private func stripView(_ card: ReplyAuthor.Card, _ url: URL) -> some View {
    RemoteArtwork(url: url) { phase in
      if let image = phase.image { image.resizable().scaledToFit() }
    }
    .frame(width: Self.strip.width, height: Self.strip.height, alignment: .trailing)
    .overlay(alignment: .trailing) {
      if !card.number.isEmpty {
        VStack(alignment: .leading, spacing: 0) {
          numberLine(card.prefix)
          numberLine(card.number)
        }
        .foregroundStyle(numberFill(card))
        .padding(.trailing, 20)
      }
    }
    .accessibilityHidden(card.number.isEmpty)
    .accessibilityLabel([card.prefix, card.number].filter { !$0.isEmpty }.joined(separator: " "))
  }
  private func numberLine(_ text: String) -> some View {
    Text(text).font(FanNumberFont.font(size: 7)).fixedSize().frame(height: 7)
  }
  /// The card's colour (the official grey-blue when it names none), or its gradient: colours at
  /// their percent stops along the start → end line.
  private func numberFill(_ card: ReplyAuthor.Card) -> AnyShapeStyle {
    let solid = Self.color(card.color) ?? Color(red: 0xBF / 255, green: 0xC8 / 255, blue: 0xD2 / 255)
    guard let g = card.gradient, g.colors.count >= 2, g.colors.count == g.stops.count else {
      return AnyShapeStyle(solid)
    }
    let stops = zip(g.colors, g.stops).compactMap { hex, at in
      Self.color(hex).map { Gradient.Stop(color: $0, location: CGFloat(at) / 100) }
    }
    guard stops.count >= 2 else { return AnyShapeStyle(solid) }
    func point(_ raw: String) -> CGPoint? {
      let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
      return parts.count == 2 ? CGPoint(x: parts[0], y: parts[1]) : nil
    }
    var start = UnitPoint.leading, end = UnitPoint.trailing
    if let s = point(g.start), let e = point(g.end) {
      if [s.x, s.y, e.x, e.y].allSatisfy({ (0...1).contains($0) }) {
        start = UnitPoint(x: s.x, y: s.y)
        end = UnitPoint(x: e.x, y: e.y)
      } else {
        // Pixel offsets in the official text box: keep their direction across the number.
        let dx = e.x - s.x, dy = e.y - s.y, span = max(abs(dx), abs(dy), 1)
        start = UnitPoint(x: 0.5 - dx / span / 2, y: 0.5 - dy / span / 2)
        end = UnitPoint(x: 0.5 + dx / span / 2, y: 0.5 + dy / span / 2)
      }
    }
    return AnyShapeStyle(LinearGradient(stops: stops, startPoint: start, endPoint: end))
  }
  @ViewBuilder private var inline: some View {
    if decorate, let card, let url = httpsURL(card.image) {
      // As in the original: the card at 38pt tall in the row's top-right corner at its natural
      // width, the fan number at its right edge where the card art leaves room for it.
      RemoteArtwork(url: url) { phase in
        if let image = phase.image {
          image.resizable().scaledToFit().frame(height: Self.height)
            .overlay(alignment: .trailing) {
              if !card.number.isEmpty {
                // The original's fan number: prefix over number in its narrow digital face,
                // centred in the card's height at its right edge.
                Text(card.prefix.isEmpty ? card.number : card.prefix + "\n" + card.number)
                  .font(FanNumberFont.font(size: 8))
                  .multilineTextAlignment(.center).lineSpacing(0)
                  .foregroundStyle(color(card.color))
                  .fixedSize()
              }
            }
        }
      }
      .frame(maxWidth: Self.width, maxHeight: Self.height, alignment: .trailing).accessibilityHidden(card.number.isEmpty).accessibilityLabel(
        [card.prefix, card.number].filter { !$0.isEmpty }.joined(separator: " "))
    }
  }
}
