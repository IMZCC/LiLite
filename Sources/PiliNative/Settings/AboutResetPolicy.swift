import Foundation

enum LocalResetPolicy {
  static let accountFolders = ["ReplyArchive", "PiliMomentDrafts", "PiliNotebook"]
  // Offline packages, the local key that opens them, granted folders and external user files are separate.
  static func removeManagedData(in root: URL, fileManager fm: FileManager = .default) throws -> URL?
  {
    let root = root.standardizedFileURL
    guard root.isFileURL,
      try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
    else { throw ServiceError("本机数据目录不可用") }
    let stage = root.appendingPathComponent(".pili-reset-" + UUID().uuidString, isDirectory: true)
    var moved: [URL] = []
    do {
      try fm.createDirectory(at: stage, withIntermediateDirectories: false)
      for name in accountFolders {
        let child = root.appendingPathComponent(name, isDirectory: true)
        guard fm.fileExists(atPath: child.path) else { continue }
        let info = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard info.isSymbolicLink != true, info.isDirectory == true else {
          throw ServiceError("本机数据目录类型不符")
        }
        try fm.moveItem(at: child, to: stage.appendingPathComponent(name, isDirectory: true))
        moved.append(child)
      }
      return stage
    } catch {
      for c in moved.reversed() {
        try fm.moveItem(
          at: stage.appendingPathComponent(c.lastPathComponent, isDirectory: true), to: c)
      }
      if fm.fileExists(atPath: stage.path) { try fm.removeItem(at: stage) }
      throw error
    }
  }
  static func finish(_ stage: URL, in root: URL, restore: Bool) throws {
    let fm = FileManager.default
    let root = root.standardizedFileURL
    let stage = stage.standardizedFileURL
    guard stage.deletingLastPathComponent().standardizedFileURL.path == root.path,
      stage.lastPathComponent.hasPrefix(".pili-reset-"),
      UUID(uuidString: String(stage.lastPathComponent.dropFirst(".pili-reset-".count))) != nil,
      try stage.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
    else { throw ServiceError("重置目录无效") }
    if restore {
      for name in accountFolders {
        let f = stage.appendingPathComponent(name, isDirectory: true)
        if fm.fileExists(atPath: f.path) {
          try fm.moveItem(at: f, to: root.appendingPathComponent(name, isDirectory: true))
        }
      }
    }
    try fm.removeItem(at: stage)
  }
}
