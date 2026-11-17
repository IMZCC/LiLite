import Foundation

enum NotebookArticle {
  static func blocks(_ ops: [[String: Any]], oid: Int64) -> [ArticleBlock] {
    var out = [ArticleBlock]()
    var group = [[String: Any]]()
    func flush() {
      if !group.isEmpty {
        out += ArticleBody.legacyOps(group)
        group = []
      }
    }
    for op in ops {
      guard let embed = op["insert"] as? [String: Any] else {
        group.append(op)
        continue
      }
      if let tag = embed["tag"] as? [String: Any], let cid = NotebookBlock.integer(tag["cid"]),
        cid > 0, let second = NotebookBlock.integer(tag["seconds"]), second >= 0,
        second < Int64(Int32.max), oid > 0
      {
        flush()
        let time = String(format: "%lld:%02lld", second / 60, second % 60)
        out.append(
          .card(
            .init(
              title: time + " " + (tag["title"] as? String ?? ""),
              detail: tag["desc"] as? String ?? "", cover: nil,
              target: .route(.positioned(.archivePart(.archive(oid, nil), cid), Double(second))))))
      } else if let image = embed["imageUpload"] as? [String: Any],
        let raw = image["url"] as? String
      {
        flush()
        let u =
          NotebookBlock.allowedImage(raw)
          ?? GalleryPicture.source(raw).flatMap { url -> URL? in
            guard let h = url.host?.lowercased(),
              ["hdslb.com", "biliimg.com"].contains(where: { h == $0 || h.hasSuffix("." + $0) })
            else { return nil }
            return url
          }
        if let u { out.append(.image(u, image["source"] as? String == "video" ? "视频截图" : "笔记图片")) }
      } else {
        group.append(op)
      }
    }
    flush()
    return out
  }
}
