import SwiftUI

/// Bilibili's level mark, drawn like the original client (`UserLevel`): a coloured tab with
/// a segmented "LV" and a seven-segment digit; hard-core members get the lightning extension.
/// Geometry is in the original 930 × 466 design units.
struct UserLevelBadge: View {
  let level: Int
  var height: CGFloat = 11
  var hardcore = false
  private static let totalR: CGFloat = 930, extendR: CGFloat = 1250, totalB: CGFloat = 466
  var body: some View {
    let width = (hardcore ? Self.extendR : Self.totalR) * height / Self.totalB
    Canvas { ctx, size in
      let s = size.height / Self.totalB
      ctx.scaleBy(x: s, y: s)
      let back = Self.color(level)
      ctx.fill(Self.backPath(hardcore), with: .color(back))
      ctx.fill(Self.lvPath, with: .color(.white))
      ctx.fill(Self.digitPath(level), with: .color(.white))
      if hardcore {
        var bolt = ctx.resolve(Image(systemName: "bolt.fill"))
        bolt.shading = .color(.white)
        ctx.draw(bolt, in: CGRect(x: 900, y: 40, width: 300, height: 400))
      }
    }
    .frame(width: width, height: height)
    .foregroundStyle(.white)
    .accessibilityElement().accessibilityLabel((hardcore ? "硬核" : "") + "\(level)级")
  }

  static func color(_ level: Int) -> Color {
    switch level {
    case ...1: Color(red: 0xC0 / 255, green: 0xC0 / 255, blue: 0xC0 / 255)
    case 2: Color(red: 0x8B / 255, green: 0xD2 / 255, blue: 0x9B / 255)
    case 3: Color(red: 0x7B / 255, green: 0xCD / 255, blue: 0xEF / 255)
    case 4: Color(red: 0xFE / 255, green: 0xBB / 255, blue: 0x8B / 255)
    case 5: Color(red: 0xEE / 255, green: 0x67 / 255, blue: 0x2A / 255)
    default: Color(red: 0xF0 / 255, green: 0x4C / 255, blue: 0x49 / 255)
    }
  }

  // MARK: geometry (ported from level_icon.dart)
  private static let r: CGFloat = 20
  private static let left: CGFloat = 629, right: CGFloat = 877, colW: CGFloat = 68
  private static let lColR = left + colW, rColL = right - colW
  private static let rowH: CGFloat = 68, rowSp: CGFloat = 146, topY: CGFloat = 55
  private static let topYB = topY + rowH, midY = topY + rowSp, midYB = midY + rowH
  private static let botY = midY + rowSp, botYB = botY + rowH
  private static let midMid = (midY + midYB) / 2

  /// Rounded rect with per-corner radii (Flutter's fromLTRBAndCorners order: tl, tr, bl, br).
  private static func rr(
    _ l: CGFloat, _ t: CGFloat, _ rgt: CGFloat, _ b: CGFloat,
    tl: CGFloat = 0, tr: CGFloat = 0, bl: CGFloat = 0, br: CGFloat = 0
  ) -> Path {
    UnevenRoundedRectangle(
      cornerRadii: .init(topLeading: tl, bottomLeading: bl, bottomTrailing: br, topTrailing: tr),
      style: .circular
    ).path(in: CGRect(x: l, y: t, width: rgt - l, height: b - t))
  }

  private static func backPath(_ bolt: Bool) -> Path {
    let rad: CGFloat = 27
    let edge = bolt ? extendR : totalR
    let blockTop: CGFloat = 48
    var p = Path()
    p.addPath(rr(0, blockTop, edge, totalB, tl: rad, bl: rad, br: rad))
    p.addPath(rr(576, 0, edge, blockTop + 1, tl: rad, tr: rad))
    return p
  }

  private static let lvPath: Path = {
    let vLeft: CGFloat = 296, lvTop: CGFloat = 106, llr: CGFloat = 123, vtb: CGFloat = 282
    var p = Path()
    // L
    p.addPath(rr(56, lvTop, llr, botYB, tl: r, tr: r, bl: r))
    p.addPath(rr(llr - 1, botY, 256, botYB, tr: r, br: r))
    // V
    p.addPath(rr(vLeft, lvTop, 363, vtb + 1, tl: r, tr: r))
    p.addPath(rr(476, lvTop, 543, vtb + 1, tl: r, tr: r))
    var v = Path()
    v.move(to: CGPoint(x: vLeft, y: vtb))
    v.addLine(to: CGPoint(x: vLeft, y: 292))
    v.addQuadCurve(to: CGPoint(x: 300, y: 313), control: CGPoint(x: vLeft, y: 309))
    v.addLine(to: CGPoint(x: 395, y: 408))
    v.addQuadCurve(to: CGPoint(x: 444, y: 408), control: CGPoint(x: 419.5, y: 432.5))
    v.addLine(to: CGPoint(x: 539, y: 313))
    v.addQuadCurve(to: CGPoint(x: 543, y: 292), control: CGPoint(x: 543, y: 309))
    v.addLine(to: CGPoint(x: 543, y: vtb))
    v.addLine(to: CGPoint(x: 476, y: vtb))
    v.addLine(to: CGPoint(x: 419.5, y: 340))
    v.addLine(to: CGPoint(x: 363, y: vtb))
    v.closeSubpath()
    p.addPath(v)
    return p
  }()

  private static func digitPath(_ digit: Int) -> Path {
    var p = Path()
    if digit == 1 {
      p.addPath(rr(673, botY, 833, botYB, tl: 20, tr: 20, bl: 20, br: 20))
      p.addPath(rr(673, topY, 787, topYB, tl: r, tr: r, bl: r))
      p.addRect(CGRect(x: 719, y: topYB, width: 787 - 719, height: botY - topYB))
      return p
    }
    let bits: Int
    switch digit {
    case 0: bits = 0x7E
    case 2: bits = 0x6D
    case 3: bits = 0x79
    case 4: bits = 0x33
    case 5: bits = 0x5B
    case 6: bits = 0x5F
    case 7: bits = 0x70
    case 8: bits = 0x7F
    case 9: bits = 0x7B
    default: bits = 0x4F
    }
    let a = bits & 0x40 != 0, b = bits & 0x20 != 0, c = bits & 0x10 != 0, d = bits & 0x08 != 0
    let e = bits & 0x04 != 0, f = bits & 0x02 != 0, g = bits & 0x01 != 0
    if a { p.addPath(rr(left, topY, right, topYB, tl: r, tr: r, bl: f ? 0 : r, br: b ? 0 : r)) }
    if g {
      p.addPath(rr(left, midY, right, midYB, tl: f ? 0 : r, tr: b ? 0 : r, bl: e ? 0 : r, br: c ? 0 : r))
    }
    if d { p.addPath(rr(left, botY, right, botYB, tl: e ? 0 : r, tr: c ? 0 : r, bl: r, br: r)) }
    if f {
      let top = (a ? topYB : topY) - 1
      let bottom = (g ? midY : (e ? midMid : midYB)) + 1
      let rt = a ? 0 : r, rb = g || e ? 0 : r
      p.addPath(rr(left, top, lColR, bottom, tl: rt, tr: rt, bl: rb, br: rb))
    }
    if b {
      let top = (a ? topYB : topY) - 1
      let bottom = (g ? midY : (c ? midMid : midYB)) + 1
      let rt = a ? 0 : r, rb = g || c ? 0 : r
      p.addPath(rr(rColL, top, right, bottom, tl: rt, tr: rt, bl: rb, br: rb))
    }
    if e {
      let top = (g ? midYB : (f ? midMid : midY)) - 1
      let bottom = (d ? botY : botYB) + 1
      let rt = g || f ? 0 : r, rb = d ? 0 : r
      p.addPath(rr(left, top, lColR, bottom, tl: rt, tr: rt, bl: rb, br: rb))
    }
    if c {
      let top = (g ? midYB : (b ? midMid : midY)) - 1
      let bottom = (d ? botY : botYB) + 1
      let rt = g || b ? 0 : r, rb = d ? 0 : r
      p.addPath(rr(rColL, top, right, bottom, tl: rt, tr: rt, bl: rb, br: rb))
    }
    return p
  }
}
