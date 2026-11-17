import Foundation

struct InlineDocument: Equatable {
  struct Link: Equatable { let range: NSRange, url: URL }
  struct ImageRun: Equatable { let range: NSRange, image: RichNode.Emote }
  struct Style: Equatable { let range: NSRange, bold: Bool, italic: Bool, strike: Bool }
  let text: String
  var links: [Link] = [], images: [ImageRun] = [], targets: [Int: RichNode.Target] = [:],
    styles: [Style] = []
  var assets: [URL] {
    Array(Set(images.map { $0.image.url })).sorted { $0.absoluteString < $1.absoluteString }
  }
  init(nodes: [RichNode]) {
    var result = ""
    var offset = 0
    for (index, node) in nodes.enumerated() {
      let length = node.text.utf16.count
      let range = NSRange(location: offset, length: length)
      offset += length
      result += node.text
      if let target = node.target {
        targets[index] = target
        links.append(.init(range: range, url: URL(string: "pili-inline://node/" + String(index))!))
      }
      if let image = node.emote { images.append(.init(range: range, image: image)) }
      if node.bold || node.italic || node.strike {
        styles.append(
          .init(range: range, bold: node.bold, italic: node.italic, strike: node.strike))
      }
    }
    text = result
  }
  init(text: String) { self.text = text }
  func target(_ url: URL) -> RichNode.Target? {
    if url.scheme == "pili-inline", url.host == "node", let key = Int(url.lastPathComponent) {
      return targets[key]
    }
    if let item = SharedLink.parse(url.absoluteString) { return .route(item) }
    return GalleryPicture.source(url.absoluteString).map(RichNode.Target.url)
  }
  func ranges(_ token: String) -> [NSRange] {
    guard !token.isEmpty else { return [] }
    let raw = text as NSString
    var out = [NSRange]()
    var from = 0
    while from < raw.length {
      let r = raw.range(
        of: token, options: [], range: NSRange(location: from, length: raw.length - from))
      guard r.location != NSNotFound, r.length > 0 else { break }
      out.append(r)
      from = NSMaxRange(r)
    }
    return out
  }
}
