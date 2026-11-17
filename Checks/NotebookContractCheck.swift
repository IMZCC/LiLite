import Foundation

@main enum NotebookContractCheck {
  typealias M = [String: Any]
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PiliNotebookFixture-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = try NotebookDisk(root: root, owner: "1", oid: 170001, note: nil)
    let other = try NotebookDisk(root: root, owner: "2", oid: 170001, note: nil)
    precondition((try? NotebookDisk(root: root, owner: "../secret", oid: 170001, note: nil)) == nil)
    let grants = try NotebookGrant.ids(["noteIds": ["4", 4, "7"]])
    let empty = try NotebookGrant.ids(["noteIds": NSNull()])
    precondition(grants == [4, 7] && empty.isEmpty && (try? NotebookGrant.ids([:])) == nil)
    let op: M = [
      "insert": "这份公开测试笔记有足够文字\n", "attributes": ["bold": true, "custom_reader_key": [1, 2]],
    ]
    let unknown: M = ["insert": ["newEmbed": ["opaque": "值"]], "attributes": ["readonly": true]]
    let t = try NotebookBlock.timestamp(cid: 997, index: 2, count: 3, seconds: 65, title: "分集")
    var b = try NotebookBlock(op)
    b.style("italic")
    var draft = NotebookDraft(
      title: "草稿", blocks: [b, t, try NotebookBlock(unknown)], base: nil, hash: 22)
    let upload = try disk.stage(Data([1, 2, 3]))
    var photo = NotebookBlock()
    photo.localPicture = upload
    photo.videoFrame = true
    draft.blocks.append(photo)
    try disk.save(draft, matching: nil)
    let same = try disk.load()
    let others = try NotebookDisk.saved(owner: "2", root: root)
    precondition(same == draft && others.isEmpty && (try? other.load()) == nil)
    let saved = try NotebookDisk.saved(owner: "1", root: root)
    precondition(saved.count == 1 && saved[0].oid == 170001)
    precondition(
      (try? draft.form(oid: 170001, note: nil, publish: true, original: false, comment: false))
        == nil)
    precondition((try? photo.uploaded("https://evil.example/x/note/image?id=4")) == nil)
    draft.blocks[draft.blocks.count - 1] = try photo.uploaded(
      "//api.bilibili.com/x/note/image?image_id=4")
    let privateForm = try draft.form(
      oid: 170001, note: 4, publish: false, original: false, comment: false)
    let publicForm = try draft.form(
      oid: 170001, note: 4, publish: true, original: false, comment: false)
    let reloaded =
      try JSONSerialization.jsonObject(with: Data(privateForm["content"]!.utf8)) as! [M]
    precondition(
      privateForm["note_id"] == "4" && privateForm["publish"] == nil
        && privateForm["tags"] == "997-2-65-0-")
    precondition(
      publicForm["publish"] == "1" && publicForm["auto_comment"] == "0"
        && publicForm["original"] == "0" && publicForm["pub_from"] == "0")
    precondition(NSDictionary(dictionary: reloaded[2]).isEqual(to: unknown))
    precondition((reloaded[0]["attributes"] as? M)?["custom_reader_key"] as? [Int] == [1, 2])
    let wire: M = [
      "note_id": 4, "oid": "170001", "oid_type": 0, "title": "草稿", "pub_status": 0,
      "pub_version": 3, "content": privateForm["content"]!,
    ]
    let current = try NotebookRemote(wire, id: 4, oid: 170001)
    precondition(
      !current.locked && draft.sameContent(as: current)
        && (try? NotebookRemote(wire, id: 5, oid: 170001)) == nil)
    for state in [1, 4, 5, 88] {
      var w = wire
      w["pub_status"] = state
      let no = try NotebookRemote(w, id: 4, oid: 170001)
      precondition(no.locked)
    }
    var denied = wire
    denied["can_edit"] = false
    let explicitlyDenied = try NotebookRemote(denied, id: 4, oid: 170001)
    precondition(explicitlyDenied.locked)
    var locked = draft
    locked.uncertain = true
    try disk.save(locked, matching: same)
    precondition((try? disk.discard(same)) == nil)
    let after = try disk.load()
    precondition(after?.uncertain == true)
    precondition(
      NotebookArchiveLink.archive([
        "web_url": "https://www.bilibili.com/h5/note-app?oid=170001&oid_type=0"
      ]) == 170001)
    precondition(
      NotebookArchiveLink.archive(["web_url": "https://evil.example/h5/note-app?oid=170001"]) == nil
    )
    let rendered = NotebookArticle.blocks(reloaded, oid: 170001)
    precondition(
      rendered.contains {
        if case .card(let c) = $0 {
          return c.target == .route(.positioned(.archivePart(.archive(170001, nil), 997), 65))
        }
        return false
      })
    precondition(
      rendered.contains {
        if case .image(let u, _) = $0 { return u.host == "api.bilibili.com" }
        return false
      })
    let legacy = ArticleBody.legacyOps([
      ["insert": "一\n二"],
      ["insert": ["article-card": ["id": "cv123", "alt": "旧专栏", "url": "//i0.hdslb.com/old.jpg"]]],
      ["insert": ["vote-card": ["id": "6"]]],
    ])
    precondition(
      legacy.count == 4
        && legacy.contains {
          if case .card(let r) = $0 { return r.target == .vote(6) }
          return false
        })
    let goods = ArticleResource.parse([
      "type": "LINK_CARD_TYPE_GOODS",
      "goods": [
        "items": [
          ["name": "样品", "jump_url": "https://www.bilibili.com/read/cv15"], ["name": "第二条"],
        ]
      ],
    ])
    let eva = ArticleResource.parse([
      "type": "LINK_CARD_TYPE_EVA3_USER",
      "eva3_user": ["info": ["user": ["mid": "18", "name": "读者"]]],
    ])
    precondition(
      goods.count == 2 && goods[0].target == .route(.article(15))
        && eva.first?.target == .route(.creator(18)))
    let invalid = ArticleResource.parse([
      "type": "LINK_CARD_TYPE_ITEM_NULL",
      "item_null": ["text": "已失效", "jump_url": "https://www.bilibili.com/read/cv5"],
    ])
    precondition(invalid.first?.title == "已失效" && invalid.first?.target == nil)
    let paragraphs = ArticleBody.opus([
      [
        "text": [
          "nodes": [
            ["formula": ["latex_content": "x^2"]],
            ["word": ["words": "大字", "font_level": "xxLarge", "color": "#CC3333"]],
          ]
        ]
      ]
    ])
    guard case .paragraph(let spans)? = paragraphs.first else { fatalError() }
    precondition(
      spans.first?.formula == "x^2" && spans.last?.fontSize == 24 && spans.last?.hexRGB == 0xCC3333)
    if CommandLine.arguments.count == 2 {
      let source = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
      guard let data = try JSONSerialization.jsonObject(with: source) as? M,
        let cv = NotebookBlock.integer(data["cvid"]), cv > 0,
        let arc = data["arc"] as? M, let oid = NotebookBlock.integer(arc["oid"]),
        let text = data["content"] as? String,
        let rows = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [M], !rows.isEmpty
      else { fatalError("invalid public response") }
      let parsed = NotebookArticle.blocks(rows, oid: oid)
      precondition(!parsed.isEmpty)
      print(
        "Native parsed public CV\(cv), AV\(oid): \(rows.count) rich-text operations, \(parsed.count) blocks"
      )
    }
    print(
      "Notebook/reading fixtures passed: scoped CAS drafts, service grants and rejection, rich delta, original fields, time links, publication intent, legacy ops, modern cards and math"
    )
  }
}
