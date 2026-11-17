import Foundation

extension BiliAPI {
  func publishedNotebook(_ id: Int64, owner: String) async throws -> ReadingDocument {
    guard id > 0 else { throw ServiceError("公开笔记编号无效") }
    let value = try await dynamicData(
      "/x/note/publish/info", ["cvid": String(id)], expectedAccount: owner)
    guard NotebookBlock.integer(value["cvid"]) == id,
      NotebookBlock.integer(value["pub_status"]) == 2,
      let data = (value["content"] as? String)?.data(using: .utf8), data.count <= 4 * 1024 * 1024,
      let ops = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]],
      let arc = value["arc"] as? [String: Any], let oid = NotebookBlock.integer(arc["oid"]), oid > 0
    else { throw ServiceError("这份公开笔记暂不可读") }
    let validArchive = (NotebookBlock.integer(arc["oid_type"]) ?? 0) == 0
    let pages = NotebookArticle.blocks(ops, oid: validArchive ? oid : 0)
    guard !pages.isEmpty else { throw ServiceError("这份笔记暂无可显示的正文") }
    var doc = (try? await reading(article: id, expectedAccount: owner)) ?? ReadingDocument()
    if doc.restriction != nil { return doc }
    if doc.commentID == nil {
      doc.article = id
      doc.commentID = id
      doc.commentType = 12
    }
    if doc.title == "专栏" || doc.title == "图文" { doc.title = value["title"] as? String ?? "视频笔记" }
    if let author = value["author"] as? [String: Any] {
      doc.author = author["name"] as? String ?? doc.author
      doc.authorID = NotebookBlock.integer(author["mid"])
      doc.signature = ReplyAuthor(dynamic: author)
    }
    doc.blocks = pages
    doc.shareCover = (arc["pic"] as? String).flatMap(GalleryPicture.source) ?? doc.shareCover
    if validArchive {
      doc.blocks.append(
        .card(
          .init(
            title: arc["title"] as? String ?? "查看视频",
            cover: (arc["pic"] as? String).flatMap(GalleryPicture.source),
            target: .route(.archive(oid, nil)))))
    }
    return doc
  }
}
