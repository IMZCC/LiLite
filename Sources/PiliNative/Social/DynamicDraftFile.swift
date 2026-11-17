import Foundation

struct DynamicShareResource: Hashable {
  let id: Int64, type: Int, title: String
  static func seasonKind(_ type: Int?) -> Int? {
    switch type {
    case 1: return 4097
    case 2: return 4098
    case 3: return 4101
    case 4: return 4100
    case 5, 7: return 4099
    default: return nil
    }
  }
  var commentOID: Int64? = nil, commentType: Int? = nil
  var author: String? = nil, cover: String? = nil, mentionID: Int64? = nil
}
struct DynamicDraftScope: Hashable {
  let owner, key: String
  static func validID(_ value: String) -> Bool {
    !value.isEmpty && value.utf8.count <= 40 && value.utf8.allSatisfy { (48...57).contains($0) }
      && value.contains { $0 != "0" }
  }
  init?(
    owner: String, repost: String? = nil, editing: String? = nil,
    resource: DynamicShareResource? = nil
  ) {
    guard Self.validID(owner),
      [repost != nil, editing != nil, resource != nil].filter({ $0 }).count <= 1,
      resource.map({ $0.id > 0 && $0.type > 0 }) ?? true, repost.map(Self.validID) ?? true,
      editing.map(Self.validID) ?? true
    else { return nil }
    self.owner = owner
    key =
      editing.map { "edit-" + $0 } ?? repost.map { "repost-" + $0 } ?? resource.map {
        "resource-\($0.type)-\($0.id)"
      } ?? "new"
  }
}
struct DynamicDraftFile: Codable, Equatable {
  struct Unit: Codable, Equatable {
    let raw: String, kind: Int, business: String
    init(_ piece: ReplyDraft.Piece) {
      raw = piece.raw
      kind = piece.kind
      business = piece.business
    }
    var piece: ReplyDraft.Piece { .init(raw: raw, kind: kind, business: business) }
  }
  enum Asset: Codable, Hashable {
    case original(String)
    case local(UUID)
  }
  var order: [Asset]?
  var ordered: [Asset] {
    let avail = (originals ?? []).map(Asset.original) + pictures.map(Asset.local)
    var seen = Set<Asset>()
    let set = Set(avail)
    return ((order ?? []) + avail).filter { set.contains($0) && seen.insert($0).inserted }
  }
  struct Tag: Codable, Equatable { let id: Int64, name: String }
  struct Reserve: Codable, Equatable { let id: Int64, title: String, start: Date, subtype: Int }
  var version = 1
  let owner, key: String
  var title = "", units = [Unit](), pictures = [UUID]()
  var originals: [String]?, base: Data?, alsoComment: Bool?
  var topic: Tag?, reserve: Reserve?, scheduled: Date?
  var privateOnly = false, comments = 0
  var cursor: Int?
  init(scope: DynamicDraftScope) {
    owner = scope.owner
    key = scope.key
  }
  var hasContent: Bool {
    !title.isEmpty || !units.isEmpty || !pictures.isEmpty || topic != nil || reserve != nil
      || alsoComment == true || privateOnly || scheduled != nil || comments > 0
  }
  func check(_ scope: DynamicDraftScope) throws {
    if scope.key.hasPrefix("resource-") || scope.key.hasPrefix("repost-") {
      guard pictures.isEmpty, title.isEmpty, !privateOnly, scheduled == nil, reserve == nil,
        topic == nil, comments == 0,
        originals == nil, !units.contains(where: { $0.kind == 4 })
      else { throw ServiceError("转发草稿含无效附件") }
    }
    guard version == 1, owner == scope.owner, key == scope.key, pictures.count <= 9,
      pictures.count + (originals?.count ?? 0) <= 9,
      Set(originals ?? []).count == (originals?.count ?? 0), Set(pictures).count == pictures.count,
      (-1...2).contains(comments),
      units.allSatisfy({ unit in
        [1, 2, 4, 9].contains(unit.kind)
          && (![2, 4].contains(unit.kind) || (Int64(unit.business) ?? 0) > 0)
      })
    else { throw ServiceError("草稿内容不完整") }
  }
  func editor() -> ReplyDraft {
    var d = ReplyDraft()
    for u in units {
      d.replace(
        nil, with: u.raw, url: u.kind == 1 ? nil : u.raw, kind: u.kind, business: u.business,
        addSpace: false)
    }
    return d
  }
  static func scheduling(_ time: Date, now: Date = .now, calendar: Calendar = .current) -> Bool {
    let start = calendar.startOfDay(for: now)
    guard let end = calendar.date(byAdding: .day, value: 8, to: start) else { return false }
    return time.timeIntervalSince(now) >= 6 * 60 && time < end
  }
}
extension ReplyDraft {
  func momentRange(kind: Int) -> (NSRange, Piece)? {
    var at = 0
    for p in pieces {
      let count = (p.raw as NSString).length
      if p.kind == kind { return (NSRange(location: at, length: count), p) }
      at += count
    }
    return nil
  }
}
struct DynamicDraftDisk {
  enum Checkpoint {
    case any
    case matches(DynamicDraftFile?)
  }
  private func verify(_ point: Checkpoint, scope: DynamicDraftScope) throws {
    if case .matches(let expected) = point, try load(scope) != expected {
      throw ServiceError("草稿已在其他窗口修改，请重新打开")
    }
  }
  let root: URL
  static var app: Self {
    .init(
      root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PiliMomentDrafts", isDirectory: true))
  }
  private func directory(_ scope: DynamicDraftScope) -> URL {
    root.appendingPathComponent(scope.owner, isDirectory: true).appendingPathComponent(
      scope.key, isDirectory: true)
  }
  private func metadata(_ scope: DynamicDraftScope) -> URL {
    directory(scope).appendingPathComponent("draft.json")
  }
  func image(_ id: UUID, scope: DynamicDraftScope) -> URL {
    directory(scope).appendingPathComponent(id.uuidString + ".jpg")
  }
  private func prepare(_ scope: DynamicDraftScope) throws {
    try FileManager.default.createDirectory(at: directory(scope), withIntermediateDirectories: true)
    #if os(iOS)
      var scoped = directory(scope)
      var values = URLResourceValues()
      values.isExcludedFromBackup = true
      try scoped.setResourceValues(values)
    #endif
  }
  func load(_ scope: DynamicDraftScope) throws -> DynamicDraftFile? {
    let u = metadata(scope)
    guard FileManager.default.fileExists(atPath: u.path) else { return nil }
    let d = try JSONDecoder().decode(DynamicDraftFile.self, from: Data(contentsOf: u))
    try validate(d, scope: scope)
    return d
  }
  private func validate(_ draft: DynamicDraftFile, scope: DynamicDraftScope) throws {
    try draft.check(scope)
    guard
      draft.pictures.allSatisfy({
        FileManager.default.fileExists(atPath: image($0, scope: scope).path)
      })
    else {
      throw ServiceError("草稿图片缺失")
    }
  }
  private func write(_ data: Data, to path: URL) throws {
    #if os(iOS)
      try data.write(
        to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: path, options: .atomic)
    #endif
  }
  func add(_ bytes: Data, scope: DynamicDraftScope) throws -> UUID {
    guard !bytes.isEmpty, bytes.count <= 16 * 1024 * 1024 else { throw ServiceError("图片过大或无法读取") }
    try prepare(scope)
    let id = UUID()
    try write(bytes, to: image(id, scope: scope))
    return id
  }
  func save(
    _ draft: DynamicDraftFile, scope: DynamicDraftScope, clean: Bool = false,
    checkpoint: Checkpoint = .any
  ) throws {
    try verify(checkpoint, scope: scope)
    try validate(draft, scope: scope)
    try prepare(scope)
    let data = try JSONEncoder().encode(draft)
    try write(data, to: metadata(scope))
    if clean {
      let keep = Set(draft.pictures)
      for url in try FileManager.default.contentsOfDirectory(
        at: directory(scope), includingPropertiesForKeys: nil)
      where url.pathExtension == "jpg" {
        if let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
          !keep.contains(id)
        {
          try? FileManager.default.removeItem(at: url)
        }
      }
    }
  }
  func discard(_ scope: DynamicDraftScope, checkpoint: Checkpoint = .any) throws {
    try verify(checkpoint, scope: scope)
    let d = directory(scope)
    if FileManager.default.fileExists(atPath: d.path) { try FileManager.default.removeItem(at: d) }
  }
}

struct DynamicRepostContext {
  var oid: Int64?, kind: Int?
  var suffix: [ReplyDraft.Piece] = []
  init(oid: Int64? = nil, kind: Int? = nil) {
    self.oid = oid
    self.kind = kind
  }
  init?(row: [String: Any], expected: String) {
    typealias Map = [String: Any]
    func value(_ x: Any?) -> String? { x as? String ?? (x as? NSNumber)?.stringValue }
    guard row["id_str"] as? String == expected else { return nil }
    let basic = row["basic"] as? Map
    oid = value(basic?["comment_id_str"]).flatMap(Int64.init)
    kind = value(basic?["comment_type"]).flatMap(Int.init)
    guard let orig = row["orig"] as? Map, orig["id_str"] as? String != nil,
      let mods = row["modules"] as? Map, let author = mods["module_author"] as? Map,
      let mid = value(author["mid"]), (Int64(mid) ?? 0) > 0, let name = author["name"] as? String,
      let d = mods["module_dynamic"] as? Map, let desc = d["desc"] as? Map
    else { return }
    suffix = [
      .init(raw: "//", kind: 1, business: ""), .init(raw: "@" + name, kind: 2, business: mid),
      .init(raw: ":", kind: 1, business: ""),
    ]
    if let nodes = desc["rich_text_nodes"] as? [Map], !nodes.isEmpty {
      for n in nodes {
        guard let text = n["orig_text"] as? String ?? n["text"] as? String else { continue }
        let user = value(n["rid"]) ?? ""
        let k = n["type"] as? String
        let type =
          k == "RICH_TEXT_NODE_TYPE_EMOJI"
          ? 9 : k == "RICH_TEXT_NODE_TYPE_AT" && (Int64(user) ?? 0) > 0 ? 2 : 1
        suffix.append(.init(raw: text, kind: type, business: type == 2 ? user : ""))
      }
    } else if let plain = desc["text"] as? String {
      suffix.append(.init(raw: plain, kind: 1, business: ""))
    }
  }
  func commentFields(_ units: [DynamicDraftFile.Unit]) -> [String: String]? {
    guard let oid, oid > 0, let kind, kind > 0 else { return nil }
    let text = units.map(\.raw).joined()
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    var out = ["oid": String(oid), "type": String(kind), "message": text]
    var names = [String: Int64]()
    for p in units where p.kind == 2 && p.raw.hasPrefix("@") {
      let name = String(p.raw.dropFirst())
      if !name.isEmpty, let mid = Int64(p.business), mid > 0, names[name] == nil {
        names[name] = mid
      }
    }
    if !names.isEmpty, let json = try? JSONEncoder().encode(names) {
      out["at_name_to_mid"] = String(decoding: json, as: UTF8.self)
    }
    return out
  }
}

enum DynamicPublishWire {
  static func receiptID(_ result: [String: Any]) -> String? {
    for key in ["dyn_id_str", "dyn_id"] {
      guard let value = (result[key] as? String) ?? (result[key] as? NSNumber)?.stringValue,
        !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }), let n = UInt64(value),
        n > 0
      else { continue }
      return value
    }
    return nil
  }
  static func body(
    draft: DynamicDraftFile, scope: DynamicDraftScope, repost: String?,
    resource: DynamicShareResource?, pictures pics: [[String: Any]], suffix: [ReplyDraft.Piece],
    uploadID: String
  ) throws -> [String: Any] {
    try draft.check(scope)
    guard DynamicDraftScope(owner: scope.owner, repost: repost, resource: resource) == scope,
      pics.count == draft.pictures.count
    else { throw ServiceError("草稿图片或发布目标不一致") }
    let units = draft.units.map(\.piece) + suffix
    let parts = units.map {
      ["raw_text": $0.raw, "type": $0.kind, "biz_id": $0.business] as [String: Any]
    }
    var content: [String: Any] = [
      "contents": parts.isEmpty
        ? [["raw_text": "", "type": 1, "biz_id": ""] as [String: Any]] : parts
    ]
    if scope.key == "new" && !draft.title.isEmpty { content["title"] = draft.title }
    var opts: [String: Any] = [:]
    if draft.privateOnly { opts["private_pub"] = 1 }
    if draft.comments == 1 { opts["close_comment"] = 1 }
    if draft.comments == 2 { opts["up_choose_comment"] = 1 }
    if let date = draft.scheduled { opts["timer_pub_time"] = Int64(date.timeIntervalSince1970) }
    var dyn: [String: Any] = [
      "content": content, "scene": resource != nil ? 5 : repost != nil ? 4 : pics.isEmpty ? 1 : 2,
      "meta": ["app_meta": ["from": "create.dynamic.web", "mobi_app": "web"]],
      "upload_id": uploadID,
    ]

    if !opts.isEmpty { dyn["option"] = opts }
    if let reserve = draft.reserve, scope.key == "new" {
      dyn["attach_card"] = [
        "common_card": [
          "type": 14, "biz_id": reserve.id, "reserve_source": 0, "reserve_lottery": 0,
        ] as [String: Any]
      ]
    }
    if let topic = draft.topic, scope.key == "new" {
      dyn["topic"] =
        ["id": topic.id, "name": topic.name, "from_source": "dyn.web.list", "from_topic_id": 0]
        as [String: Any]
    }
    if !pics.isEmpty { dyn["pics"] = pics }
    var body: [String: Any] = ["dyn_req": dyn]
    if let repost { body["web_repost_src"] = ["dyn_id_str": repost] }
    if let resource {
      body["web_repost_src"] = [
        "revs_id": ["rid": resource.id, "dyn_type": resource.type] as [String: Any]
      ]
    }
    return body
  }
}
