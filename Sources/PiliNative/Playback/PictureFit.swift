import Foundation

enum PictureFit: String, CaseIterable {
  case stretch, fit, fill, width, height, original, down, fourThree, sixteenNine
  var title: String {
    switch self {
    case .stretch: "拉伸"
    case .fit: "适应画面"
    case .fill: "裁切填充"
    case .width: "等宽"
    case .height: "等高"
    case .original: "原始大小"
    case .down: "仅缩小"
    case .fourThree: "4:3"
    case .sixteenNine: "16:9"
    }
  }
  struct Geometry { let size: CGSize, gravity: String }
  func geometry(view: CGSize, source: CGSize, firstChoice: Bool = false) -> Geometry {
    let v = view, s = source
    guard v.width.isFinite, v.height.isFinite, min(v.width, v.height) > 0,
      s.width.isFinite, s.height.isFinite, min(s.width, s.height) > 0
    else { return Geometry(size: v, gravity: "fit") }
    let x = v.width / s.width, y = v.height / s.height
    let scale: CGFloat
    switch self {
    case .stretch: return .init(size: v, gravity: firstChoice && s.height > s.width ? "fit" : "stretch")
    case .fit: return .init(size: v, gravity: "fit")
    case .fill: return .init(size: v, gravity: "fill")
    case .width: scale = x
    case .height: scale = y
    case .original: scale = 1
    case .down: scale = min(1, min(x, y))
    case .fourThree, .sixteenNine:
      let ratio: CGFloat = self == .fourThree ? 4.0 / 3 : 16.0 / 9
      let w = min(v.width, v.height * ratio)
      return .init(size: .init(width: w, height: w / ratio), gravity: "stretch")
    }
    return .init(size: .init(width: s.width * scale, height: s.height * scale), gravity: "stretch")
  }
}
