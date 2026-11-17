import Foundation

enum FolderExport {
  struct File { let source: URL, stem: String, ext: String }
  static func stem(_ hint: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
    let text = String(String.UnicodeScalarView(hint.unicodeScalars.filter(allowed.contains)))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return String((text.isEmpty ? "图片" : text).prefix(54))
  }
  static func safeExt(_ value: String) -> String {
    let s = value.lowercased()
    return !s.isEmpty && s.utf8.count <= 8
      && s.utf8.allSatisfy { (48...57).contains($0) || (97...122).contains($0) } ? s : "img"
  }
  /// Publish without replacing anything. Name collisions can also come from another app.
  static func publish(_ source: URL, in folder: URL, stem hint: String, ext: String?) throws -> URL
  {
    let base = stem(hint)
    let suffix = ext.map { "." + safeExt($0) } ?? ""
    for n in 1...10000 {
      let name = base + (n == 1 ? "" : " (\(n))") + suffix
      let target = folder.appendingPathComponent(name)
      if FileManager.default.fileExists(atPath: target.path) { continue }
      do {
        try FileManager.default.moveItem(at: source, to: target)
        return target
      } catch let e as NSError
        where e.domain == NSCocoaErrorDomain && e.code == NSFileWriteFileExistsError
      { continue }
    }
    throw ServiceError("文件夹中存在过多同名文件")
  }
  /// A batch and a Live Photo become visible as one folder, after every file has been copied.
  static func write(_ files: [File], into folder: URL, group: String?) throws {
    guard !files.isEmpty else { throw ServiceError("没有可导出的图片") }
    let fm = FileManager.default
    let temp = folder.appendingPathComponent(".pili-export-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: temp, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: temp) }
    for (index, f) in files.enumerated() {
      try Task.checkCancellation()
      let sourceInfo = try f.source.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ])
      guard sourceInfo.isRegularFile == true, sourceInfo.isSymbolicLink != true,
        (sourceInfo.fileSize ?? 0) > 0
      else { throw ServiceError("图片文件不完整") }
      let part = temp.appendingPathComponent(".part-" + String(index))
      try fm.copyItem(at: f.source, to: part)
      if files.count == 1 && group == nil {
        _ = try publish(part, in: folder, stem: f.stem, ext: f.ext)
      } else {
        _ = try publish(part, in: temp, stem: f.stem, ext: f.ext)
      }
    }
    if files.count > 1 || group != nil {
      _ = try publish(temp, in: folder, stem: group ?? "轻哩 图片", ext: nil)
    }
  }
}
