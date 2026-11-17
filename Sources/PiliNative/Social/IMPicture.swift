import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IMImageFormat: String {
  case jpeg, png, gif
  var ext: String { self == .jpeg ? "jpg" : rawValue }
  var mime: String { "image/" + rawValue }
}
struct IMOutgoingPicture {
  let bytes: Data, format: IMImageFormat
  init(_ input: Data) throws {
    guard !input.isEmpty, input.count <= 24 * 1024 * 1024,
      let src = CGImageSourceCreateWithData(
        input as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
      let kind = CGImageSourceGetType(src)
    else { throw ServiceError("无法读取图片") }
    let t = UTType(kind as String)
    let f: IMImageFormat =
      t?.conforms(to: .gif) == true ? .gif : t?.conforms(to: .png) == true ? .png : .jpeg
    let uti: UTType = f == .gif ? .gif : f == .png ? .png : .jpeg
    let count = f == .jpeg ? 1 : CGImageSourceGetCount(src)
    guard (1...200).contains(count) else { throw ServiceError("图片帧数过多") }
    let out = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(out, uti.identifier as CFString, count, nil)
    else { throw ServiceError("图片格式不支持") }
    if f == .gif, let global = CGImageSourceCopyProperties(src, nil) as? [String: Any],
      let g = global[kCGImagePropertyGIFDictionary as String] as? [String: Any],
      let loop = g[kCGImagePropertyGIFLoopCount as String]
    {
      CGImageDestinationSetProperties(
        dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop]] as CFDictionary)
    }
    var pixels = 0
    for i in 0..<count {
      guard let p = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any],
        let w = p[kCGImagePropertyPixelWidth as String] as? Int,
        let h = p[kCGImagePropertyPixelHeight as String] as? Int,
        (1...20000).contains(w), (1...20000).contains(h), w * h <= 40_000_000,
        pixels <= 160_000_000 - w * h
      else { throw ServiceError("图片尺寸过大") }
      pixels += w * h
      // Re-encode only display pixels, orientation and animation timing; never send GPS/EXIF or embedded thumbnails.
      guard
        let image = CGImageSourceCreateImageAtIndex(
          src, i, [kCGImageSourceShouldCache: false] as CFDictionary)
      else { throw ServiceError("图片解码失败") }
      var meta = [String: Any]()
      if let o = p[kCGImagePropertyOrientation as String] {
        meta[kCGImagePropertyOrientation as String] = o
      }
      if f == .jpeg { meta[kCGImageDestinationLossyCompressionQuality as String] = 0.96 }
      if f == .gif, let g = p[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
        let timing = g.filter {
          [kCGImagePropertyGIFDelayTime as String, kCGImagePropertyGIFUnclampedDelayTime as String]
            .contains($0.key)
        }
        meta[kCGImagePropertyGIFDictionary as String] = timing
      }
      if f == .png, let g = p[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
        let timing = g.filter {
          [
            kCGImagePropertyAPNGDelayTime as String,
            kCGImagePropertyAPNGUnclampedDelayTime as String,
            kCGImagePropertyAPNGLoopCount as String,
          ].contains($0.key)
        }
        meta[kCGImagePropertyPNGDictionary as String] = timing
      }
      CGImageDestinationAddImage(dest, image, meta as CFDictionary)
      guard out.length <= 24 * 1024 * 1024 else { throw ServiceError("图片超过 24 MB") }
    }
    guard CGImageDestinationFinalize(dest), out.length > 0, out.length <= 24 * 1024 * 1024 else {
      throw ServiceError("无法导出图片")
    }
    bytes = out as Data
    format = f
  }
}
