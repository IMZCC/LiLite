import Foundation

struct NotebookBlock: Identifiable, Codable, Equatable {
  typealias Map = [String: Any]
  var id = UUID()
  var raw: Data
  var localPicture: UUID?
  var videoFrame = false
  init(_ op: Map) throws {
    raw = try JSONSerialization.data(withJSONObject: op, options: .sortedKeys)
  }
  init(text: String = "") {
    raw =
      (try? JSONSerialization.data(withJSONObject: ["insert": text], options: .sortedKeys))
      ?? Data()
  }
  var object: Map { ((try? JSONSerialization.jsonObject(with: raw)) as? Map) ?? [:] }
  var insert: Map? { object["insert"] as? Map }
  var words: String? { object["insert"] as? String }
  var attributes: Map { object["attributes"] as? Map ?? [:] }
  var tag: Map? { insert?["tag"] as? Map }
  var photo: Map? { insert?["imageUpload"] as? Map }
  mutating func setText(_ s: String) {
    var op = object
    op["insert"] = s
    if let data = try? JSONSerialization.data(withJSONObject: op, options: .sortedKeys) {
      raw = data
    }
  }
  mutating func style(_ k: String) {
    guard ["bold", "italic", "underline", "strike"].contains(k) else { return }
    var op = object
    var a = attributes
    if a[k] as? Bool == true { a[k] = nil } else { a[k] = true }
    op["attributes"] = a
    if let v = try? JSONSerialization.data(withJSONObject: op, options: .sortedKeys) { raw = v }
  }
  static func integer(_ v: Any?) -> Int64? {
    (v as? NSNumber)?.int64Value ?? (v as? String).flatMap(Int64.init)
  }
  static func timestamp(cid: Int64, index: Int, count: Int, seconds: Int, title: String) throws
    -> Self
  {
    guard cid > 0, index > 0, count >= index, seconds >= 0 else { throw ServiceError("无法取得当前分集") }
    return try Self([
      "insert": [
        "tag": [
          "cid": String(cid), "index": index, "seconds": seconds, "cidCount": count, "status": 0,
          "key": Int64(Date().timeIntervalSince1970 * 1000), "title": title, "desc": "",
          "oid_type": 0,
        ] as Map
      ]
    ])
  }
  static func allowedImage(_ value: String) -> URL? {
    var s = value
    if s.hasPrefix("//") { s = "https:" + s }
    if s.hasPrefix("/x/note/image?") { s = "https://api.bilibili.com" + s }
    guard let u = URL(string: s), u.scheme == "https", u.host?.lowercased() == "api.bilibili.com",
      u.user == nil, u.password == nil, u.port == nil || u.port == 443, u.path == "/x/note/image"
    else { return nil }
    return u
  }
  func uploaded(_ location: String) throws -> Self {
    guard let u = Self.allowedImage(location) else { throw ServiceError("笔记图片地址不正确") }
    var copy = try Self([
      "insert": [
        "imageUpload": [
          "id": id.uuidString, "status": "done", "url": u.absoluteString, "width": 480,
          "source": videoFrame ? "video" : "local",
        ] as Map
      ]
    ])
    copy.id = id
    return copy
  }
}
enum NotebookGrant {
  static func ids(_ value: [String: Any]) throws -> [Int64] {
    let field = value["noteIds"] ?? value["note_ids"]
    if field is NSNull { return [] }
    guard let rows = field as? [Any] else { throw ServiceError("未能确认当前账号的笔记列表") }
    var seen = Set<Int64>()
    return try rows.map { entry -> Int64 in
      guard let id = NotebookBlock.integer(entry), id > 0 else { throw ServiceError("笔记编号无效") }
      return id
    }.filter { seen.insert($0).inserted }
  }
}
struct NotebookRemote {
  typealias Map = [String: Any]
  let id: Int64, title: String, blocks: [NotebookBlock], base: Data, locked: Bool, status: Int?,
    reason: String?
  init(_ data: Map, id: Int64, oid: Int64) throws {
    guard id > 0, oid > 0, NotebookBlock.integer(data["note_id"]).map({ $0 == id }) != false,
      NotebookBlock.integer(data["oid"]).map({ $0 == oid }) != false,
      NotebookBlock.integer(data["oid_type"]).map({ $0 == 0 }) != false
    else { throw ServiceError("笔记与视频不匹配") }
    guard let text = data["content"] as? String, text.utf8.count <= 4 * 1024 * 1024,
      let ops = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Map],
      ops.count <= 40000
    else { throw ServiceError("无法读取笔记正文") }
    guard ops.allSatisfy({ $0["insert"] != nil }) else { throw ServiceError("这份笔记需要用原编辑器打开") }
    self.id = id
    title = data["title"] as? String ?? ""
    blocks = try ops.map { try NotebookBlock($0) }
    status = NotebookBlock.integer(data["pub_status"]).flatMap(Int.init(exactly:))
    reason = data["pub_reason"] as? String
    locked =
      (status.map { ![0, 2, 3, 6].contains($0) } ?? true) || data["can_edit"] as? Bool == false
      || data["is_editable"] as? Bool == false
    base = try JSONSerialization.data(
      withJSONObject: [
        "ops": ops, "title": title, "status": status ?? -1,
        "version": data["pub_version"] ?? NSNull(),
      ], options: .sortedKeys)
  }
}
struct NotebookDraft: Codable, Equatable {
  var title: String, blocks: [NotebookBlock], base: Data?, hash: Int64
  var uncertain = false
  func sameContent(as remote: NotebookRemote) -> Bool {
    guard title == remote.title, blocks.allSatisfy({ $0.localPicture == nil }) else { return false }
    let a = blocks.map(\.raw)
    let b = remote.blocks.map(\.raw)
    return a == b
  }
  var bodyText: String { blocks.compactMap(\.words).joined() }
  func form(oid: Int64, note: Int64?, publish: Bool, original: Bool, comment: Bool) throws
    -> [String: String]
  {
    guard oid > 0, note.map({ $0 > 0 }) != false, !title.isEmpty, (title as NSString).length <= 40,
      !blocks.isEmpty, !blocks.contains(where: { $0.localPicture != nil }),
      !blocks.contains(where: { $0.words == nil && $0.insert == nil })
    else { throw ServiceError("笔记内容不完整") }
    let plain = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
    let length = (plain as NSString).length
    let pics = blocks.compactMap(\.photo)
    let tags = blocks.compactMap(\.tag)
    guard length <= 20000, tags.count <= (publish ? 200 : 2000),
      pics.count <= (publish ? 100 : 200), length > 0 || !pics.isEmpty || !tags.isEmpty
    else { throw ServiceError("笔记文字或附件数量不合适") }
    if publish && length < 10 && !pics.contains(where: { $0["source"] as? String == "video" }) {
      throw ServiceError("公开笔记需要至少 10 个字或 1 张视频截图")
    }
    guard pics.allSatisfy({ $0["url"] as? String != nil }) else { throw ServiceError("有图片尚未上传") }
    let encoded = try JSONSerialization.data(
      withJSONObject: blocks.map(\.object), options: .sortedKeys)
    let tagStrings = try tags.enumerated().map { index, t -> String in
      guard
        let cid = NotebookBlock.integer(t["epid"]).flatMap({ $0 > 0 ? $0 : nil })
          ?? NotebookBlock.integer(t["cid"]), cid > 0, let page = NotebookBlock.integer(t["index"]),
        let seconds = NotebookBlock.integer(t["seconds"]), seconds >= 0
      else { throw ServiceError("时间标记信息不完整") }
      return "\(cid)-\(page)-\(seconds)-\(index)-" + (t["desc"] as? String ?? "")
    }
    var f = [
      "oid": String(oid), "oid_type": "0", "title": title,
      "content": String(decoding: encoded, as: UTF8.self), "summary": String(plain.prefix(160)),
      "tags": tagStrings.joined(separator: ","), "cls": "1", "cont_len": String(length),
      "from": "save", "hash": String(hash), "platform": "ios",
    ]
    if let note { f["note_id"] = String(note) }
    if publish {
      f["publish"] = "1"
      f["original"] = original ? "1" : "0"
      f["auto_comment"] = comment ? "1" : "0"
      f["pub_from"] = "0"
      f["comment_format"] = "2"
    }
    return f
  }
}
struct NotebookDisk {
  let folder: URL
  init(root: URL? = nil, owner: String, oid: Int64, note: Int64?) throws {
    guard !owner.isEmpty, owner.utf8.allSatisfy({ (48...57).contains($0) }),
      Int64(owner).map({ $0 > 0 }) == true, oid > 0, note.map({ $0 > 0 }) != false
    else { throw ServiceError("笔记账号或编号无效") }
    let parent =
      root
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("PiliNotebook", isDirectory: true)
    folder = parent.appendingPathComponent(owner, isDirectory: true).appendingPathComponent(
      String(oid), isDirectory: true
    ).appendingPathComponent(note.map(String.init) ?? "new", isDirectory: true)
  }
  struct Saved: Identifiable {
    let oid: Int64, note: Int64?, title: String, time: Date
    var id: String { String(oid) + ":" + (note.map(String.init) ?? "new") }
  }
  static func saved(owner: String, root: URL? = nil) throws -> [Saved] {
    let test = try Self(root: root, owner: owner, oid: 1, note: nil)
    let u = test.folder.deletingLastPathComponent().deletingLastPathComponent()
    let fm = FileManager.default
    if !fm.fileExists(atPath: u.path) { return [] }
    var rows = [Saved]()
    for dir in try fm.contentsOfDirectory(
      at: u, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
      options: .skipsHiddenFiles)
    {
      guard let n = Int64(dir.lastPathComponent), n > 0,
        (try? dir.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
      else { continue }
      for target in try fm.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: .skipsHiddenFiles)
      {
        let name = target.lastPathComponent
        let id = Int64(name)
        guard name == "new" || id.map({ $0 > 0 }) == true,
          (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else { continue }
        let disk = try Self(root: root, owner: owner, oid: n, note: id)
        let meta = disk.folder.appendingPathComponent("draft.json")
        if let d = try? disk.load() {
          rows.append(
            .init(
              oid: n, note: id, title: d.title,
              time: (try? meta.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate) ?? .distantPast))
        }
      }
    }
    return rows.sorted { $0.time > $1.time }
  }
  func load() throws -> NotebookDraft? {
    let u = folder.appendingPathComponent("draft.json")
    guard FileManager.default.fileExists(atPath: u.path) else { return nil }
    return try JSONDecoder().decode(NotebookDraft.self, from: Data(contentsOf: u))
  }
  func save(_ draft: NotebookDraft, matching expected: NotebookDraft?) throws {
    guard try load() == expected else { throw ServiceError("另一窗口已更改这份草稿") }
    try prepare()
    try JSONEncoder().encode(draft).write(
      to: folder.appendingPathComponent("draft.json"), options: .atomic)
  }
  private func prepare() throws {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var f = folder
    var opts = URLResourceValues()
    opts.isExcludedFromBackup = true
    try f.setResourceValues(opts)
  }
  func pic(_ id: UUID) -> URL { folder.appendingPathComponent(id.uuidString + ".jpg") }
  func stage(_ data: Data) throws -> UUID {
    guard !data.isEmpty, data.count <= 12 * 1024 * 1024 else { throw ServiceError("图片过大") }
    try prepare()
    let id = UUID()
    try data.write(to: pic(id), options: .atomic)
    return id
  }
  func discard(_ expected: NotebookDraft?) throws {
    guard try load() == expected else { throw ServiceError("另一窗口已更改这份草稿") }
    if FileManager.default.fileExists(atPath: folder.path) {
      try FileManager.default.removeItem(at: folder)
    }
  }
}

enum NotebookArchiveLink {
  static func archive(_ row: [String: Any]) -> Int64? {
    if let n = NotebookBlock.integer(row["oid"] ?? (row["arc"] as? [String: Any])?["aid"]), n > 0,
      NotebookBlock.integer(row["oid_type"]).map({ $0 == 0 }) != false
    {
      return n
    }
    guard let s = row["web_url"] as? String, let c = URLComponents(string: s),
      c.scheme == "https" || (c.scheme == nil && s.hasPrefix("//")), c.user == nil,
      c.password == nil, c.port == nil,
      ["www.bilibili.com", "m.bilibili.com", "bilibili.com"].contains(c.host?.lowercased() ?? ""),
      ["/h5/note-app", "/h5/note-app/", "/h5/note-app/edit", "/h5/note-app/view"].contains(c.path),
      let items = c.queryItems, items.filter({ $0.name == "oid" }).count == 1,
      let v = items.first(where: { $0.name == "oid" })?.value, let n = Int64(v), n > 0,
      items.first(where: { $0.name == "oid_type" })?.value.map({ $0 == "0" }) != false
    else { return nil }
    return n
  }
}
