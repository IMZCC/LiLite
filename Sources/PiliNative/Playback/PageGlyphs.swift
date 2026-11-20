import SwiftUI

// Glyphs of the original client's video page that SF Symbols has no match for, drawn here in its
// style (nothing of the original's artwork is bundled).

/// 投币: a solid disc with the 币 mark cut out of it — a bar, an arch under it and a stem through
/// both.
struct CoinMark: View {
  var color: Color
  var body: some View {
    GeometryReader { g in
      let d = min(g.size.width, g.size.height)
      Circle().fill(color)
        .mask {
          ZStack {
            Circle()
            CoinStroke().stroke(style: StrokeStyle(lineWidth: d * 0.085, lineCap: .round, lineJoin: .round))
              .blendMode(.destinationOut)
          }
          .compositingGroup()
        }
        .frame(width: d, height: d)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .accessibilityHidden(true)
  }
}
private struct CoinStroke: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    let x = { (f: CGFloat) in r.minX + r.width * f }
    let y = { (f: CGFloat) in r.minY + r.height * f }
    p.move(to: CGPoint(x: x(0.3), y: y(0.31)))
    p.addLine(to: CGPoint(x: x(0.7), y: y(0.31)))
    p.move(to: CGPoint(x: x(0.31), y: y(0.66)))
    p.addCurve(to: CGPoint(x: x(0.69), y: y(0.66)),
      control1: CGPoint(x: x(0.31), y: y(0.4)), control2: CGPoint(x: x(0.69), y: y(0.4)))
    p.move(to: CGPoint(x: x(0.5), y: y(0.31)))
    p.addLine(to: CGPoint(x: x(0.5), y: y(0.73)))
    return p
  }
}

/// The original's fullscreen button: two open corners, top left and bottom right.
struct FullscreenCorners: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    let x = { (f: CGFloat) in r.minX + r.width * f }
    let y = { (f: CGFloat) in r.minY + r.height * f }
    p.move(to: CGPoint(x: x(0.08), y: y(0.5)))
    p.addLine(to: CGPoint(x: x(0.08), y: y(0.08)))
    p.addLine(to: CGPoint(x: x(0.5), y: y(0.08)))
    p.move(to: CGPoint(x: x(0.92), y: y(0.5)))
    p.addLine(to: CGPoint(x: x(0.92), y: y(0.92)))
    p.addLine(to: CGPoint(x: x(0.5), y: y(0.92)))
    return p
  }
}
struct FullscreenCornersGlyph: View {
  var body: some View {
    FullscreenCorners()
      .stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
      .frame(width: 17, height: 17)
  }
}

/// 投屏 as the original draws it: "TV" in a rounded screen, a small cast triangle breaking its
/// bottom edge.
struct CastTVGlyph: View {
  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 5.5, style: .continuous)
        .stroke(lineWidth: 1.8)
        .frame(width: 22, height: 18)
        .mask {
          ZStack {
            Rectangle()
            Rectangle().frame(width: 9, height: 6).offset(y: 9).blendMode(.destinationOut)
          }
          .compositingGroup()
          .frame(width: 26, height: 22)
        }
      Text("TV").font(.system(size: 9.5, weight: .heavy, design: .rounded)).offset(y: -0.5)
      CastTriangle()
        .stroke(style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        .frame(width: 6.5, height: 4.5)
        .offset(y: 9.5)
    }
    .frame(width: 26, height: 24)
    .accessibilityHidden(true)
  }
}
private struct CastTriangle: Shape {
  func path(in r: CGRect) -> Path {
    var p = Path()
    p.move(to: CGPoint(x: r.midX, y: r.minY))
    p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
    p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
    p.closeSubpath()
    return p
  }
}

/// The bullet switch beside "点我发弹幕": a screen of bullet lines with a tick (on) or a cross
/// (off) at its corner.
struct DanmakuSwitchGlyph: View {
  let on: Bool
  var body: some View {
    ZStack(alignment: .bottomTrailing) {
      ZStack {
        RoundedRectangle(cornerRadius: 4.5, style: .continuous)
          .stroke(lineWidth: 1.7)
          .frame(width: 19, height: 16)
        VStack(alignment: .leading, spacing: 3.2) {
          bulletLine(9)
          bulletLine(7)
        }
        .offset(x: 0.5)
      }
      .foregroundStyle(Color.secondary)
      .mask {
        ZStack(alignment: .bottomTrailing) {
          Rectangle()
          Circle().frame(width: 11, height: 11).offset(x: 3, y: 3).blendMode(.destinationOut)
        }
        .compositingGroup()
      }
      Image(systemName: on ? "checkmark" : "xmark")
        .font(.system(size: on ? 8.5 : 7.5, weight: .heavy))
        .foregroundStyle(on ? Color.accentColor : Color.secondary)
        .offset(x: 2, y: 2.5)
        .contentTransition(.symbolEffect(.replace))
    }
    .frame(width: 22, height: 19)
    .accessibilityHidden(true)
  }
  private func bulletLine(_ length: CGFloat) -> some View {
    HStack(spacing: 2.2) {
      Capsule().frame(width: 2, height: 1.7)
      Capsule().frame(width: length, height: 1.7)
    }
  }
}
