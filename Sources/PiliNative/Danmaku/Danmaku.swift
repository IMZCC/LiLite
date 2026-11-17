import Foundation

#if canImport(FoundationXML)
  import FoundationXML
#endif

struct Bullet: Equatable, Codable, Sendable {
  static let vipGradient = 60001
  var isVIPGradient: Bool { colorType == Self.vipGradient }
  let time: Double
  let mode: Int
  let rgb: Int
  let text: String
  var wireText: String? = nil
  var fontSize: Double = 25
  var special: SpecialBullet? = nil
  var sender: String? = nil, entryID: Int64? = nil, weight: Int? = nil, colorType: Int? = nil,
    likes: Int? = nil
}
final class DanmakuXML: NSObject, XMLParserDelegate {
  private var pending: (Double, Int, Int, Double)?
  private var sender: String?, entryID: Int64?, weight: Int?
  private var text = ""
  private var bullets: [Bullet] = []
  static func parse(_ data: Data) throws -> [Bullet] {
    let decoder = DanmakuXML()
    let p = XMLParser(data: data)
    p.shouldResolveExternalEntities = false
    p.delegate = decoder
    guard p.parse() else { throw ServiceError("弹幕暂时无法读取") }
    return decoder.bullets.sorted { $0.time < $1.time }
  }
  func parser(
    _ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
    qualifiedName: String?, attributes attrs: [String: String] = [:]
  ) {
    guard name == "d" else { return }
    pending = nil
    text = ""
    let f = (attrs["p"] ?? "").split(separator: ",", omittingEmptySubsequences: false)
    guard f.count >= 4, let t = Double(f[0]), t.isFinite, t >= 0,
      let mode = Int(f[1]), (1...9).contains(mode), let rgb = Int(f[3])
    else { return }
    pending = (t, mode, rgb, Double(f[2]).flatMap { $0.isFinite ? $0 : nil } ?? 25)
    sender = f.indices.contains(6) && !f[6].isEmpty ? String(f[6]) : nil
    entryID = f.indices.contains(7) ? Int64(f[7]) : nil
    weight = f.indices.contains(8) ? Int(f[8]) : nil
  }
  func parser(_ parser: XMLParser, foundCharacters string: String) {
    if pending != nil { text += string }
  }
  func parser(
    _ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?
  ) {
    guard name == "d", let (t, mode, rgb, font) = pending else { return }
    if mode == 7 {
      if let s = SpecialBullet(text) {
        bullets.append(
          .init(
            time: t, mode: mode, rgb: rgb, text: s.text, wireText: text, fontSize: font.isFinite ? font : 25,
            special: s, sender: sender, entryID: entryID, weight: weight))
      }
    } else if !text.isEmpty {
      bullets.append(
        .init(
          time: t, mode: mode, rgb: rgb, text: text, fontSize: font, sender: sender,
          entryID: entryID, weight: weight))
    }
    pending = nil
  }
}
