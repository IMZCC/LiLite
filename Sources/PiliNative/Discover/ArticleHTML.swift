import Foundation
import libxml2

extension ArticleBody {
  static func originalHTMLImage(_ raw: String) -> URL? {
    guard let url = GalleryPicture.source(raw), let host = url.host?.lowercased(),
      ["hdslb.com", "biliimg.com"].contains(where: { host == $0 || host.hasSuffix("." + $0) }),
      var c = URLComponents(url: url, resolvingAgainstBaseURL: false), c.query == nil,
      c.fragment == nil,
      let mark = c.percentEncodedPath.range(
        of: #"@(?:[0-9]+[a-z]_?)+(?:\.[A-Za-z0-9]+)?$"#, options: .regularExpression)
    else { return GalleryPicture.source(raw) }
    c.percentEncodedPath = String(c.percentEncodedPath[..<mark.lowerBound])
    return c.url
  }
  static func html(_ raw: String) -> [ArticleBlock] {
    let bytes = Array(raw.utf8)
    guard !bytes.isEmpty, bytes.count <= 8 * 1024 * 1024 else { return [] }
    let options =
      HTML_PARSE_RECOVER.rawValue | HTML_PARSE_NOERROR.rawValue | HTML_PARSE_NOWARNING.rawValue
      | HTML_PARSE_NONET.rawValue
    let document = bytes.withUnsafeBytes { p in
      htmlReadMemory(
        p.baseAddress?.assumingMemoryBound(to: CChar.self), Int32(p.count), nil, "UTF-8",
        Int32(options))
    }
    guard let doc = document else { return [] }
    defer { xmlFreeDoc(doc) }
    var result: [ArticleBlock] = []
    var line: [ArticleSpan] = []
    enum Kind { case text, heading, quote, code }
    func flush(_ k: Kind) {
      guard !line.isEmpty else { return }
      if line.contains(where: { !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
      {
        switch k {
        case .text: result.append(.paragraph(line))
        case .heading: result.append(.heading(line))
        case .quote: result.append(.quote(line))
        case .code: result.append(.code(line.map(\.value).joined()))
        }
      }
      line = []
    }
    func walk(_ base: xmlNodePtr?, _ style: ArticleSpan, _ kind: Kind, _ depth: Int) {
      guard depth < 96 else { return }
      var next = base
      while let n = next {
        next = n.pointee.next
        if n.pointee.type == XML_TEXT_NODE || n.pointee.type == XML_CDATA_SECTION_NODE {
          if let content = n.pointee.content {
            var s = style
            s.value = String(cString: content)
            line.append(s)
          }
          continue
        }
        guard n.pointee.type == XML_ELEMENT_NODE, let key = n.pointee.name else { continue }
        let name = String(cString: key).lowercased()
        if ["script", "style", "template", "noscript", "iframe", "object", "head"].contains(name) {
          continue
        }
        func attr(_ key: String) -> String? {
          guard let v = xmlGetProp(n, key) else { return nil }
          defer { xmlFree(v) }
          return String(cString: v)
        }
        var s = style
        var format = kind
        switch name {
        case "strong", "b": s.bold = true
        case "i", "em": s.italic = true
        case "s", "strike", "del": s.strike = true
        case "a": s.url = attr("href").flatMap(httpsURL)
        case "img":
          flush(kind)
          if let u = (attr("data-original") ?? attr("data-src") ?? attr("src")).flatMap(
            originalHTMLImage)
          {
            result.append(.image(u, attr("alt") ?? ""))
          }
          continue
        case "hr":
          flush(kind)
          result.append(.divider)
          continue
        case "br":
          var l = s
          l.value = "\n"
          line.append(l)
          continue
        case "h1", "h2", "h3", "h4", "h5", "h6": format = .heading
        case "pre": format = .code
        case "blockquote": format = .quote
        default: break
        }
        let block = [
          "p", "h1", "h2", "h3", "h4", "h5", "h6", "div", "li", "pre", "blockquote", "figcaption",
          "figure", "tr",
        ].contains(name)
        if block { flush(kind) }
        if name == "li" { line.append(.init(value: "• ")) }
        walk(n.pointee.children, s, format, depth + 1)
        if block { flush(format) }
      }
    }
    walk(xmlDocGetRootElement(doc), .init(value: ""), .text, 0)
    flush(.text)
    return result
  }
}
