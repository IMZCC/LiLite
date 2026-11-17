import Foundation

@main struct ReplyDomainAudit {
  static func main() async throws {
    var rule = ReplyFilterRules()
    rule.pattern = "广告"
    let added = try rule.addingLiteral(".*a|b")
    let filtered = ReplyFilter(rules: added, blocked: [], intro: nil)
    precondition(
      filtered.hides(
        author: nil, body: "看到 .*a|b", mentions: [], hasMedia: false, hasGoods: false, nested: false
      ))
    precondition(
      !filtered.hides(
        author: nil, body: "a", mentions: [], hasMedia: false, hasGoods: false, nested: false))
    let top = ReplyComposeAddress(owner: "41", oid: 170001, type: 1, root: nil, parent: nil)!
    let second = ReplyComposeAddress(owner: "41", oid: 170001, type: 1, root: 101, parent: 101)!
    let conversation = ReplyComposeAddress(
      owner: "41", oid: 170001, type: 1, root: 101, parent: 105)!
    precondition(top.pictureAllowed && !second.pictureAllowed && !conversation.pictureAllowed)
    precondition(ReplyComposeAddress(owner: "0", oid: 1, type: 1, root: nil, parent: nil) == nil)
    precondition(ReplyComposeAddress(owner: "41", oid: 1, type: 1, root: 101, parent: nil) == nil)
    var draft = ReplyDraft()
    var caret = draft.replace(nil, with: "😀 ")
    caret = draft.replace(caret, with: "@阿猫", url: "@阿猫", kind: 2, business: "9007199254740999")
    caret = draft.replace(caret, with: "资料", url: "https://www.bilibili.com/read/cv1")
    draft.replace(caret, with: #"$\frac{a+b}{2}$ $$x^2+\alpha_1$$"#)
    let original = draft.text
    precondition(
      draft.toggleMath() == nil && draft.raw.contains("(a+b)/2") && draft.raw.contains("x²+α₁"))
    precondition(draft.raw.contains("https://www.bilibili.com/read/cv1"))
    let computed = draft.raw
    let fields = try conversation.fields(
      text: computed, mentionIDs: draft.mentionIDs(), share: true, targetName: "甲")
    precondition(
      fields["root"] == "101" && fields["parent"] == "105" && fields["sync_to_dynamic"] == "1"
        && fields["message"] == " 回复 @甲 : " + computed)
    let mapping = try JSONDecoder().decode(
      [String: Int64].self, from: Data(fields["at_name_to_mid"]!.utf8))
    precondition(mapping == ["阿猫": 9_007_199_254_740_999])
    precondition(draft.toggleMath() == nil && draft.text == original)
    let one = try second.fields(text: "答复", mentionIDs: [:], share: true, targetName: "甲")
    precondition(one["message"] == "答复" && one["at_name_to_mid"] == nil)
    let main = try top.fields(text: "主楼", mentionIDs: [:], share: false, targetName: nil)
    precondition(main["root"] == nil && main["parent"] == nil && main["sync_to_dynamic"] == nil)
    let matrix = ReplyMath.spans(#"$\begin{matrix}a&b\\c&d\end{matrix}$"#)
    precondition(
      matrix.0.count == 1 && matrix.0[0].display.contains("┌") && matrix.0[0].display.contains("d")
        && matrix.1.isEmpty)
    let malformed = ReplyMath.spans(#"$\sqrt{bad$"#)
    precondition(malformed.0.isEmpty && !malformed.1.isEmpty)
    precondition(
      ReplyComposeAddress.timestamp(3661.5) == "1:01:01"
        && ReplyComposeAddress.timestamp(.nan) == nil)
    let id = Int64.max - 7
    let object: [String: Any] = [
      "rpid_str": "\(id)", "rpid": NSNumber(value: id), "mid": "41", "oid": 170001, "type": 1,
      "parent": "105", "root": "101",
      "member": ["uname": "甲", "mid": "41", "level_info": ["current_level": 4]], "ctime": 1234,
      "content": [
        "message": "@甲", "at_name_to_mid": ["甲": "41"],
        "pictures": [["img_src": "https://i0.hdslb.com/a.jpg", "img_width": 8, "img_height": 12]],
      ],
    ]
    func receipt(_ row: [String: Any], _ code: Int = 0) throws -> Data {
      try JSONSerialization.data(withJSONObject: ["code": code, "data": ["reply": row]])
    }
    let accepted = try receipt(object)
    precondition(conversation.receiptID(accepted) == id && top.receiptID(accepted) == nil)
    for (key, other) in [
      ("root", "2"), ("parent", "0"), ("type", "33"), ("oid", "1"), ("mid", "99"),
      ("mid", "broken"),
    ] {
      var mismatch = object
      mismatch[key] = other
      let bytes = try receipt(mismatch)
      precondition(conversation.receiptID(bytes) == nil)
    }
    let rejected = try receipt(object, -101)
    precondition(conversation.receiptID(rejected) == nil)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let archive = ReplyArchive(directory: dir)
    try await archive.capture(accepted, oid: 170001, type: 1, root: 101, uid: "41")
    let rows = try await archive.items("41")
    let otherAccount = try await archive.items("42")
    precondition(rows.map(\.id) == [id] && otherAccount.isEmpty)
    let bytes = try await archive.export("41")
    let arr = try JSONSerialization.jsonObject(with: bytes) as! [[String: Any]]
    precondition(
      arr.first?["parent"] as? String == "105" && arr.first?["id"] as? String == String(id))
    let content = arr.first!["content"] as! [String: Any]
    precondition(
      (content["pictures"] as? [[String: String]])?.first?["imgHeight"] == "12"
        && (content["atNameToMid"] as? [String: String])?["甲"] == "41")
    try await archive.importData(bytes, uid: "41")
    do {
      try await archive.capture(accepted, oid: 170001, type: 1, root: 101, uid: "42")
      preconditionFailure("other owner accepted")
    } catch {}
    do {
      try await archive.capture(rejected, oid: 170001, type: 1, root: 101, uid: "41")
      preconditionFailure("failed write recorded")
    } catch {}
    let restored = try await archive.items("41")
    precondition(restored.count == 1 && restored[0].id == id)
    print(
      "reply domain: retained 64-bit identities, zero/negative receipts, account and thread drafts, structured mentions, formulas, cloud archive round trip"
    )
  }
}
