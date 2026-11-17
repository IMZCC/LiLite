import SwiftUI
import UIKit

/// Immutable glyph images avoid shaping and drawing nine text runs on every animation frame.
/// The shared, bounded cache also survives the inline/fullscreen handoff.
final class BulletRasterCache: @unchecked Sendable {
  static let shared = BulletRasterCache()
  struct Style: Hashable {
    let text: String, prefix: String
    let point: Double, weight: Int, stroke: Double, scale: Double
    let rgb: Int, gradient: Bool, shadow: Bool
  }
  final class Raster: @unchecked Sendable {
    let image: CGImage, size: CGSize, scale: Double, inset: Double
    init(_ image: CGImage, size: CGSize, scale: Double, inset: Double) {
      self.image = image; self.size = size; self.scale = scale; self.inset = inset
    }
  }
  private final class Key: NSObject {
    let value: Style
    init(_ value: Style) { self.value = value }
    override var hash: Int { value.hashValue }
    override func isEqual(_ other: Any?) -> Bool { (other as? Key)?.value == value }
  }
  private let cache = NSCache<Key, Raster>()
  private init() { cache.totalCostLimit = 32 * 1024 * 1024; cache.countLimit = 512 }
  static func weight(_ value: Int) -> UIFont.Weight {
    [.ultraLight, .thin, .light, .regular, .medium, .semibold, .bold, .heavy, .black][min(8, max(0, value - 1))]
  }
  static func style(_ bullet: Bullet, repeats: Int = 1, point: Double, layout: DanmakuStyle, scale: Double) -> Style {
    let advanced = bullet.special
    return .init(text: advanced?.text ?? bullet.text, prefix: advanced == nil && repeats > 1 ? "(\(repeats))" : "",
      point: advanced == nil ? point : min(8192, max(1, bullet.fontSize)), weight: layout.fontWeight,
      stroke: advanced == nil || advanced?.stroke == true ? layout.stroke : 0, scale: scale,
      rgb: advanced == nil && layout.monochrome ? 0xffffff : bullet.rgb,
      gradient: advanced == nil && layout.showVIP && bullet.isVIPGradient, shadow: advanced != nil)
  }
  func image(_ spec: Style) -> Raster? {
    let key = Key(spec)
    if let hit = cache.object(forKey: key) { return hit }
    guard spec.point.isFinite, spec.point > 0, spec.scale.isFinite, spec.scale > 0 else { return nil }
    let font = UIFont.systemFont(ofSize: spec.point, weight: Self.weight(spec.weight))
    let badge = UIFont.systemFont(ofSize: spec.point * 0.6, weight: Self.weight(spec.weight))
    let text = NSMutableAttributedString(string: spec.prefix, attributes: [.font: badge])
    text.append(NSAttributedString(string: spec.text, attributes: [.font: font]))
    let inset = spec.shadow ? ceil(spec.stroke * 2) : spec.stroke / 2
    let measured = text.size()
    let size = CGSize(width: ceil(measured.width + inset * 2), height: ceil(max(font.lineHeight, measured.height) + inset * 2))
    guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
    // Keep oversized imported text on the same bounded background path as ordinary glyphs.
    let scale = min(3, spec.scale, 8191 / max(size.width, size.height),
      sqrt(64_000 / (size.width * size.height)))
    let format = UIGraphicsImageRendererFormat()
    format.scale = scale; format.opaque = false; format.preferredRange = .standard
    let origin = CGPoint(x: inset, y: inset)
    let black = NSMutableAttributedString(attributedString: text)
    black.addAttribute(.foregroundColor, value: UIColor.black, range: NSRange(location: 0, length: black.length))
    let color = UIColor(red: Double(spec.rgb >> 16 & 255) / 255, green: Double(spec.rgb >> 8 & 255) / 255, blue: Double(spec.rgb & 255) / 255, alpha: 1)
    text.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: text.length))
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      let cg = context.cgContext
      if spec.stroke > 0 && !spec.shadow {
        if spec.gradient { cg.beginTransparencyLayer(auxiliaryInfo: nil) }
        for (dx, dy) in [(-1.0, 0.0), (1.0, 0.0), (0.0, -1.0), (0.0, 1.0), (-0.707, -0.707), (0.707, -0.707), (-0.707, 0.707), (0.707, 0.707)] {
          black.draw(at: CGPoint(x: origin.x + dx * spec.stroke / 2, y: origin.y + dy * spec.stroke / 2))
        }
        if spec.gradient {
          cg.setBlendMode(.sourceIn)
          if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [UIColor(red: 242/255, green: 80/255, blue: 158/255, alpha: 1).cgColor, UIColor(red: 48/255, green: 139/255, blue: 205/255, alpha: 1).cgColor] as CFArray, locations: [0, 1]) {
            cg.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: 0), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
          }
          cg.setBlendMode(.normal); cg.endTransparencyLayer()
        }
      }
      if spec.shadow && spec.stroke > 0 { cg.setShadow(offset: .zero, blur: spec.stroke, color: UIColor.black.cgColor) }
      text.draw(at: origin)
    }
    guard let cg = image.cgImage else { return nil }
    let raster = Raster(cg, size: size, scale: scale, inset: inset)
    cache.setObject(raster, forKey: key, cost: cg.bytesPerRow * cg.height)
    return raster
  }
}
