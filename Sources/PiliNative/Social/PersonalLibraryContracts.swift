import Foundation

enum LocalCreatorBlockFile {
  static let limit = 2 * 1024 * 1024
  static func decode(_ data: Data) throws -> Set<Int64> {
    guard !data.isEmpty, data.count <= limit else { throw ServiceError("黑名单文件过大或为空") }
    let raw = try JSONDecoder().decode([Int64].self, from: data)
    let values = Set(raw)
    guard values.count <= RecommendationRules.creatorLimit, values.allSatisfy({ $0 > 0 }) else {
      throw ServiceError("黑名单需要有效的 UID")
    }
    return values
  }
  static func encode(_ ids: Set<Int64>) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted]
    return try encoder.encode(ids.sorted())
  }
  static func merge(_ incoming: Set<Int64>, defaults: UserDefaults = .standard) throws -> Int {
    var rules = RecommendationRules.current(defaults)
    let old = rules.blockedCreators.count
    rules.blockedCreators.formUnion(incoming)
    try rules.save(defaults)
    return rules.blockedCreators.count - old
  }
}
enum LibraryCheckedOrder {
  static func items(display: [String], selected: Set<String>, movingFavorite: Bool) throws -> [String] {
    var seen = Set<String>()
    let ordered = display.filter { selected.contains($0) && seen.insert($0).inserted }
    guard seen == selected else { throw ServiceError("列表已更新，请重新选择") }
    return movingFavorite ? Array(ordered.reversed()) : ordered
  }
}
struct FollowGroupCommand {
  let owner: String, path: String, fields: [String: String]
  static func custom(_ id: Int) -> Bool { ![0, -10, -2].contains(id) }
  enum Edit { case add(String), rename(Int, String), remove(Int), order([Int]) }
  init(_ edit: Edit, owner: String) throws {
    guard Int64(owner).map({ $0 > 0 && String($0) == owner }) == true else { throw ServiceError("请先登录") }
    self.owner = owner
    func name(_ text: String) throws -> String {
      let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !s.isEmpty && s.count <= 16 else { throw ServiceError("分组名称限 1–16 个字") }
      return s
    }
    switch edit {
    case .add(let text):
      path = "/x/relation/tag/create"
      fields = ["tag": try name(text)]
    case .rename(let id, let text):
      guard Self.custom(id) else { throw ServiceError("内建分组不能修改") }
      path = "/x/relation/tag/update"
      fields = ["tagid": String(id), "name": try name(text)]
    case .remove(let id):
      guard Self.custom(id) else { throw ServiceError("内建分组不能删除") }
      path = "/x/relation/tag/del"
      fields = ["tagid": String(id)]
    case .order(let ids):
      guard !ids.isEmpty, Set(ids).count == ids.count, ids.allSatisfy(Self.custom) else {
        throw ServiceError("只能调整自建分组的顺序")
      }
      path = "/x/relation/tags/update_sort"
      fields = ["tagids": ids.map(String.init).joined(separator: ",")]
    }
  }
  func apply(active: String?, submit: (String, [String: String], String) async throws -> Void) async throws {
    try check(active: active)
    try Task.checkCancellation()
    try await submit(path, fields, owner)
  }
  func check(active: String?) throws {
    guard active == owner else { throw ServiceError("账号已切换") }
  }
}

enum SpaceArchiveTarget {
  static func resolve(bvid: String, cid: Int64, course: Bool, uri: String, redirect: String) -> SharedLink? {
    if course { return episode(uri, course: true) }
    if !redirect.isEmpty { return episode(redirect, course: false) }
    return cid > 0 ? .archivePart(.video(bvid, nil), cid) : .video(bvid, nil)
  }
  private static func episode(_ uri: String, course: Bool) -> SharedLink? {
    if let route = SharedLink.parse(uri) {
      switch route {
      case .episode(let id): return course ? .course(id, true) : route
      case .season(let id): return course ? .course(id, false) : route
      case .course: return course ? route : nil
      default: break
      }
    }
    guard let u = URLComponents(string: uri), u.user == nil, u.password == nil, u.port == nil,
      let host = u.host?.lowercased(), ((u.scheme == "bilibili" && ["cheese", "pgc", "bangumi", "m.bilibili.com", "www.bilibili.com"].contains(host)) || (["http","https"].contains(u.scheme ?? "") && (host == "bilibili.com" || host.hasSuffix(".bilibili.com")))),
      let field = u.path.split(separator: "/").last, field.hasPrefix("ep") || field.hasPrefix("ss"),
      field.dropFirst(2).allSatisfy({ $0.isASCII && $0.isNumber }), let id = Int64(field.dropFirst(2)), id > 0 else { return nil }
    return course ? .course(id,field.hasPrefix("ep")) : field.hasPrefix("ep") ? .episode(id) : .season(id)
  }
}
