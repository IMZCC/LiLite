import Foundation

@main enum DynamicDraftCheck {
  typealias Map = [String: Any]
  static func main() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "moment-fixture-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let disk = DynamicDraftDisk(root: root)
    let scope = DynamicDraftScope(owner: "91")!
    let other = DynamicDraftScope(owner: "92")!
    let forward = DynamicDraftScope(owner: "91", repost: "82")!
    let edit = DynamicDraftScope(owner: "91", editing: "82")!
    let resource = DynamicShareResource(id: 82, type: 4300, title: "收藏夹")
    let fav = DynamicDraftScope(owner: "91", resource: resource)!
    precondition(Set([scope, other, forward, edit, fav]).count == 5)
    precondition(
      DynamicDraftScope(owner: "../91") == nil
        && DynamicDraftScope(owner: "11", repost: "1", resource: resource) == nil)
    precondition(DynamicDraftScope(owner: "11", repost: "8/abc") == nil)
    var body = ReplyDraft()
    body.change(to: "🏖️左尾")
    let cursor = NSRange(location: ("🏖️左" as NSString).length, length: 0)
    let mark = body.replace(cursor, with: "@同名", url: "@同名", kind: 2, business: "806")
    let end = body.replace(mark, with: "[猫]", url: "[猫]", kind: 9, addSpace: false)
    body.replace(end, with: "选择", url: "选择", kind: 4, business: "701")
    var d = DynamicDraftFile(scope: scope)
    d.units = body.pieces.map(DynamicDraftFile.Unit.init)
    d.cursor = end.location
    d.title = "图片与实体"
    let a = try disk.add(Data([0x1, 0x2]), scope: scope)
    let b = try disk.add(Data([3, 4]), scope: scope)
    d.pictures = [b, a]
    d.topic = .init(id: 17, name: "话题")
    d.reserve = .init(id: 12, title: "直播", start: .now, subtype: 0)
    d.privateOnly = true
    d.comments = 2
    try disk.save(d, scope: scope, checkpoint: .matches(nil))
    let restored = try disk.load(scope)!
    precondition(
      restored == d && restored.editor().pieces == body.pieces
        && restored.editor().text == body.text)
    let noOther = try disk.load(other)
    precondition(noOther == nil)
    let firstBytes = try Data(contentsOf: disk.image(restored.pictures[0], scope: scope))
    precondition(firstBytes == Data([3, 4]))
    var changed = restored.editor()
    let at = changed.momentRange(kind: 2)!.0
    let editAt = NSRange(location: at.location + 1, length: 1)
    changed.change(
      to: (changed.text as NSString).replacingCharacters(in: editAt, with: "新"), hint: (editAt, "新")
    )
    precondition(
      changed.momentRange(kind: 2) == nil && changed.momentRange(kind: 4)?.1.business == "701")
    let json = try DynamicPublishWire.body(
      draft: d, scope: scope, repost: nil, resource: nil,
      pictures: [["img_src": "b"], ["img_src": "a"]], suffix: [], uploadID: "test")
    let req = json["dyn_req"] as! Map
    let pieces = (req["content"] as! Map)["contents"] as! [Map]
    precondition(pieces.compactMap { $0["type"] as? Int } == body.pieces.map(\.kind))
    precondition(
      pieces.first(where: { $0["type"] as? Int == 2 })?["biz_id"] as? String == "806"
        && (req["option"] as! Map)["up_choose_comment"] as? Int == 1)
    precondition(
      req["scene"] as? Int == 2
        && ((req["attach_card"] as! Map)["common_card"] as! Map)["biz_id"] as? Int64 == 12)
    var modern = d
    modern.title = "另一个窗口"
    try disk.save(modern, scope: scope, checkpoint: .matches(d))
    do {
      try disk.save(d, scope: scope, checkpoint: .matches(d))
      preconditionFailure("stale write")
    } catch {}
    do {
      try disk.discard(scope, checkpoint: .matches(d))
      preconditionFailure("stale deletion")
    } catch {}
    var missing = modern
    missing.pictures = [UUID()]
    do {
      try disk.save(missing, scope: scope)
      preconditionFailure("missing file")
    } catch {}
    let surviving = try disk.load(scope)!
    precondition(surviving == modern)
    let seasonKinds = [1: 4097, 2: 4098, 3: 4101, 4: 4100, 5: 4099, 7: 4099]
    for key in 0...9 { precondition(DynamicShareResource.seasonKind(key) == seasonKinds[key]) }
    precondition(DynamicShareResource.seasonKind(nil) == nil)
    let r = try DynamicPublishWire.body(
      draft: .init(scope: fav), scope: fav, repost: nil, resource: resource, pictures: [],
      suffix: [], uploadID: "0_example")
    let target = (r["web_repost_src"] as! Map)["revs_id"] as! Map
    precondition(
      (r["dyn_req"] as! Map)["scene"] as? Int == 5 && target["rid"] as? Int64 == 82
        && target["dyn_type"] as? Int == 4300)
    let contextRow: Map = [
      "id_str": "82", "orig": ["id_str": "11"],
      "basic": ["comment_id_str": "90", "comment_type": 17],
      "modules": [
        "module_author": ["mid": "73", "name": "甲"],
        "module_dynamic": [
          "desc": [
            "rich_text_nodes": [
              ["type": "RICH_TEXT_NODE_TYPE_EMOJI", "orig_text": "[好]"]
            ]
          ]
        ],
      ],
    ]
    let ctx = DynamicRepostContext(row: contextRow, expected: "82")!
    precondition(DynamicRepostContext(row: contextRow, expected: "8") == nil)
    precondition(ctx.suffix.map(\.raw).joined() == "//@甲:[好]" && ctx.suffix[1].business == "73")
    let comments = ctx.commentFields(d.units)!
    precondition(
      comments["oid"] == "90" && comments["message"] == body.text
        && comments["at_name_to_mid"]?.contains("806") == true)
    let f = try DynamicPublishWire.body(
      draft: .init(scope: forward), scope: forward, repost: "82", resource: nil, pictures: [],
      suffix: ctx.suffix, uploadID: "test")
    precondition(
      (f["dyn_req"] as! Map)["scene"] as? Int == 4
        && (f["web_repost_src"] as! Map)["dyn_id_str"] as? String == "82")
    let now = Date(timeIntervalSince1970: 1_730_000_000)
    precondition(
      !DynamicDraftFile.scheduling(now.addingTimeInterval(359), now: now)
        && DynamicDraftFile.scheduling(now.addingTimeInterval(361), now: now))
    precondition(!DynamicDraftFile.scheduling(now.addingTimeInterval(9 * 86400), now: now))
    let item: Map = [
      "id_str": "82", "type": "DYNAMIC_TYPE_DRAW",
      "modules": [
        "module_author": ["mid": "91"],
        "module_dynamic": [
          "desc": ["text": "原文"],
          "additional": [
            "type": "ADDITIONAL_TYPE_VOTE", "vote": ["vote_id": "77", "title": "投票"],
          ],
        ],
      ],
    ]
    let revision = try DynamicRevision(row: item, expected: "91", id: "82")
    precondition(revision.editor().momentRange(kind: 4)?.1.business == "77")
    let add = revision.payload(
      contents: revision.pieces, title: "", pictures: [], topicID: nil, topicName: nil,
      isPrivate: false, replyMode: -1, uploadID: "test", reserve: .use(200))
    precondition(
      (((add["dyn_req"] as! Map)["attach_card"] as! Map)["common_card"] as! Map)["biz_id"]
        as? String == "200")
    var assets = DynamicDraftFile(scope: edit)
    assets.originals = ["a", "b"]
    assets.pictures = [a]
    assets.order = [.original("b"), .local(a), .original("a")]
    precondition(assets.ordered == [.original("b"), .local(a), .original("a")])
    assets.originals = ["a"]
    precondition(assets.ordered == [.local(a), .original("a")])
    print(
      "PASS: account/target-separated text & image drafts; optimistic saves; UTF-16 entities; new, nested and collection reposts; edit attachments; scheduling"
    )
  }
}
