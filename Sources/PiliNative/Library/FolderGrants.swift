import Foundation

enum FolderPurpose: String { case pictures, cache }
struct LocalFolderChoice: Identifiable, Equatable { let id: UUID, name: String }

/// Bookmark bytes are device-local and excluded from all application backup/export formats.
actor FolderGrants {
  static let shared = FolderGrants()
  private struct Grant: Codable {
    let id: UUID
    var name: String, bookmark: Data
  }
  private struct State: Codable {
    var grants: [Grant] = []
    var pictures: UUID?, cache: UUID?
  }
  private var cached: State?
  private var file: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("LocalFolderAccess", isDirectory: true).appendingPathComponent(
        "folders.json")
  }
  private func state() throws -> State {
    if let cached { return cached }
    let u = file
    if !FileManager.default.fileExists(atPath: u.path) { return State() }
    let s = try JSONDecoder().decode(State.self, from: Data(contentsOf: u))
    cached = s
    return s
  }
  private func save(_ s: State) throws {
    let u = file
    var parent = u.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    var options = URLResourceValues()
    options.isExcludedFromBackup = true
    try parent.setResourceValues(options)
    try JSONEncoder().encode(s).write(
      to: u, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    cached = s
  }
  func current(_ purpose: FolderPurpose) throws -> LocalFolderChoice? {
    let s = try state()
    let id = purpose == .cache ? s.cache : s.pictures
    guard let id else { return nil }
    guard let grant = s.grants.first(where: { $0.id == id }) else { throw ServiceError("请重新选择文件夹") }
    return .init(id: grant.id, name: grant.name)
  }
  func choices() throws -> [LocalFolderChoice] {
    try state().grants.map { .init(id: $0.id, name: $0.name) }
  }
  func reset(_ purpose: FolderPurpose) throws {
    var s = try state()
    if purpose == .cache { s.cache = nil } else { s.pictures = nil }
    try save(s)
  }
  @discardableResult func select(_ picked: URL, for purpose: FolderPurpose) throws
    -> LocalFolderChoice
  {
    guard picked.isFileURL, picked.startAccessingSecurityScopedResource() else {
      throw ServiceError("文件夹未授权")
    }
    defer { picked.stopAccessingSecurityScopedResource() }
    let info = try picked.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard info.isDirectory == true && info.isSymbolicLink != true else {
      throw ServiceError("请选择文件夹")
    }
    var s = try state()
    var found: Grant?
    var coordError: NSError?
    let registered = s.grants
    NSFileCoordinator(filePresenter: nil).coordinate(
      readingItemAt: picked, options: .withoutChanges, error: &coordError
    ) { inside in
      found = registered.first { g in
        var stale = false
        if let u = try? URL(
          resolvingBookmarkData: g.bookmark, options: .withoutUI, relativeTo: nil,
          bookmarkDataIsStale: &stale),
          u.standardizedFileURL == picked.standardizedFileURL
        {
          return true
        }
        return ((try? OfflinePackage.folder(inside, id: g.id, create: false)) ?? nil) != nil
      }
    }
    if let coordError { throw coordError }
    let id = found?.id ?? UUID()
    let name = String(picked.lastPathComponent.prefix(128))
    let g = Grant(
      id: id, name: name,
      bookmark: try picked.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil))
    if let i = s.grants.firstIndex(where: { $0.id == id }) {
      s.grants[i] = g
    } else {
      s.grants.append(g)
    }
    if purpose == .cache { s.cache = id } else { s.pictures = id }
    try save(s)
    return .init(id: id, name: name)
  }
  func withFolder<T>(_ id: UUID, writing: Bool, _ body: @escaping (URL) throws -> T) throws -> T {
    var s = try state()
    guard let i = s.grants.firstIndex(where: { $0.id == id }) else {
      throw ServiceError("找不到文件夹授权，请重新选择")
    }
    var stale = false
    let u = try URL(
      resolvingBookmarkData: s.grants[i].bookmark, options: .withoutUI, relativeTo: nil,
      bookmarkDataIsStale: &stale)
    guard u.isFileURL, u.startAccessingSecurityScopedResource() else {
      throw ServiceError("无法访问文件夹，请重新授权")
    }
    defer { u.stopAccessingSecurityScopedResource() }
    if stale {
      s.grants[i].bookmark = try u.bookmarkData(
        options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
      s.grants[i].name = String(u.lastPathComponent.prefix(128))
      try save(s)
    }
    let coordinator = NSFileCoordinator(filePresenter: nil)
    var err: NSError?
    var result: Result<T, Error>?
    let run: (URL) -> Void = { actual in
      result = Result {
        try FolderAccessIO.requireDirectory(actual)
        return try body(actual)
      }
    }
    if writing {
      coordinator.coordinate(writingItemAt: u, options: .forMerging, error: &err, byAccessor: run)
    } else {
      coordinator.coordinate(
        readingItemAt: u, options: .withoutChanges, error: &err, byAccessor: run)
    }
    if let err { throw err }
    guard let result else { throw ServiceError("文件夹没有响应") }
    return try result.get()
  }
}
