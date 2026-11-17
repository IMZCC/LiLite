import Foundation

struct ReplyComposeAddress: Hashable {
  let owner: String, oid: Int64, type: Int, root: Int64?, parent: Int64?
  init?(owner: String, oid: Int64, type: Int, root: Int64?, parent: Int64?) {
    guard let actor = Int64(owner), actor > 0, String(actor) == owner, oid > 0, type > 0,
      (root == nil) == (parent == nil), root.map({ $0 > 0 }) != false,
      parent.map({ $0 > 0 }) != false
    else { return nil }
    self.owner = owner
    self.oid = oid
    self.type = type
    self.root = root
    self.parent = parent
  }
  var pictureAllowed: Bool { root == nil }
  func fields(text: String, mentionIDs: [String: Int64], share: Bool, targetName: String?) throws
    -> [String: String]
  {
    var content = text
    if let parent, let root, parent != root, let name = targetName, !name.isEmpty {
      content = " 回复 @" + name + " : " + content
    }
    var f = ["oid": String(oid), "type": String(type), "message": content]
    if let root, let parent {
      f["root"] = String(root)
      f["parent"] = String(parent)
    }
    if share { f["sync_to_dynamic"] = "1" }
    if !mentionIDs.isEmpty {
      f["at_name_to_mid"] = String(decoding: try JSONEncoder().encode(mentionIDs), as: UTF8.self)
    }
    return f
  }
  func receiptID(_ data: Data) -> Int64? {
    typealias M = [String: Any]
    guard let e = (try? JSONSerialization.jsonObject(with: data)) as? M, e["code"] as? Int == 0,
      let row = (e["data"] as? M)?["reply"] as? M
    else { return nil }
    func n(_ v: Any?) -> Int64? {
      if let s = v as? String { return Int64(s) }
      guard let n = v as? NSNumber, String(cString: n.objCType) != "c" else { return nil }
      return Int64(n.stringValue)
    }
    func matches(_ key: String, _ expected: Int64) -> Bool {
      guard let value = row[key] else { return true }
      return n(value) == expected
    }
    guard matches("oid", oid), matches("type", Int64(type)), matches("mid", Int64(owner)!),
      matches("root", root ?? 0), matches("parent", parent ?? 0),
      let id = n(row["rpid_str"] ?? row["rpid"]), id > 0
    else { return nil }
    return id
  }
  static func timestamp(_ seconds: Double) -> String? {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int32.max) else { return nil }
    let n = Int(seconds)
    return n >= 3600
      ? String(format: "%d:%02d:%02d", n / 3600, (n / 60) % 60, n % 60)
      : String(format: "%02d:%02d", n / 60, n % 60)
  }
}
