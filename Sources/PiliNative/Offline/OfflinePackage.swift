import Foundation

#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

/// Only app-owned packages with the expected generation, file set and content may be adopted or removed.
enum OfflinePackage {
  struct Part: Codable, Equatable { let bytes: Int64, hash: String }
  struct Receipt: Codable, Equatable { let token: String, parts: [String: Part] }
  typealias Hasher = (URL) throws -> String
  static let fm = FileManager.default
  static func name(_ c: String) throws -> String {
    if LegacyMediaComponents.isPart(c) { return c + ".mp4" }
    if c.hasPrefix("bound-"), LegacyMediaComponents.isPart(String(c.dropFirst(6))) { return c + ".pilicache" }
    switch c {
    case "movie": return "movie.mp4"
    case "video": return "video.mp4"
    case "audio": return "audio.m4a"
    case "bound-audio", "bound-video", "bound-movie": return c + ".pilicache"
    default: throw ServiceError("缓存轨道无效")
    }
  }
  static func validToken(_ token: String) -> Bool {
    token.range(
      of:
        "^BV[0-9A-Za-z]{10}-[0-9]+(~(g|u[0-9]{1,20})(~[pc][0-9]{1,20})?)?:(original|[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12})$",
      options: .regularExpression) != nil
  }
  static func package(_ root: URL, _ token: String) throws -> URL {
    guard validToken(token) else { throw ServiceError("缓存编号无效") }
    return root.appendingPathComponent(
      token.replacingOccurrences(of: ":", with: "_"), isDirectory: true)
  }
  static func folder(_ parent: URL, id: UUID, create: Bool) throws -> URL? {
    let directory = parent.appendingPathComponent("PiliNative-" + id.uuidString, isDirectory: true)
    let marker = directory.appendingPathComponent(".pili-owner")
    let identity = Data(id.uuidString.utf8)
    if !fm.fileExists(atPath: directory.path) {
      guard create else { return nil }
      try fm.createDirectory(at: directory, withIntermediateDirectories: false)
      try identity.write(to: marker, options: .withoutOverwriting)
    }
    try FolderAccessIO.requireDirectory(directory)
    guard try FolderAccessIO.readSmall(marker) == identity else {
      throw ServiceError("所选文件夹里的缓存目录不属于此授权")
    }
    return directory
  }
  static func size(_ url: URL) throws -> Int64 {
    let r = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard r.isRegularFile == true, r.isSymbolicLink != true, let n = r.fileSize, n > 0 else {
      throw ServiceError("缓存轨道不可用")
    }
    return Int64(n)
  }
  static func describe(_ token: String, files: [String: URL], hash: Hasher) throws -> Receipt {
    guard validToken(token), !files.isEmpty else { throw ServiceError("缓存没有媒体文件") }
    var parts: [String: Part] = [:]
    for (key, file) in files {
      _ = try name(key)
      parts[key] = .init(bytes: try size(file), hash: try hash(file))
      try Task.checkCancellation()
    }
    return .init(token: token, parts: parts)
  }
  static func requireAuthority(_ observed: [String:String], proof: [String:String], components: [String]) throws {
    guard !components.isEmpty, Set(components) == Set(proof.keys), observed == proof,
      proof.values.allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } })
    else { throw ServiceError("新位置的缓存不完整，已保留原文件") }
  }
  static func verified(
    _ pkg: URL, token: String, components: [String], hash: Hasher?, allowExtras: Bool = false
  ) throws
    -> Receipt
  {
    try FolderAccessIO.requireDirectory(pkg)
    let receipt = try JSONDecoder().decode(
      Receipt.self, from: FolderAccessIO.readSmall(pkg.appendingPathComponent("receipt.json")))
    guard receipt.token == token, Set(receipt.parts.keys) == Set(components), !components.isEmpty
    else { throw ServiceError("缓存文件身份不匹配") }
    let allowed = try Set(components.map(name)).union(["receipt.json"])
    let names = Set(try fm.contentsOfDirectory(atPath: pkg.path))
    guard allowExtras || names == allowed else {
      throw ServiceError("缓存目录含其他文件，已保留原文件")
    }
    for key in components {
      let u = try pkg.appendingPathComponent(name(key))
      guard let part = receipt.parts[key], part.bytes == (try size(u)), part.hash.utf8.count == 64
      else { throw ServiceError("缓存文件大小已变化") }
      if let hash, try hash(u) != part.hash { throw ServiceError("缓存内容已变化，已保留原文件") }
    }
    return receipt
  }
  static func work(_ pkg: URL) -> URL {
    pkg.deletingLastPathComponent().appendingPathComponent(
      ".pili-transfer-" + pkg.lastPathComponent, isDirectory: true)
  }
  private static func discardWork(_ temp: URL, token: String, components: [String]) throws {
    guard fm.fileExists(atPath: temp.path) else { return }
    try FolderAccessIO.requireDirectory(temp)
    let names = Set(try fm.contentsOfDirectory(atPath: temp.path))
    if !names.isEmpty {
      let marker = names.contains("work.json") ? "work.json" : "receipt.json"
      let receipt = try JSONDecoder().decode(
        Receipt.self, from: FolderAccessIO.readSmall(temp.appendingPathComponent(marker)))
      let allowed = try Set(components.map(name)).union(["work.json", "receipt.json"])
      guard receipt.token == token, Set(receipt.parts.keys) == Set(components),
        names.isSubset(of: allowed)
      else { throw ServiceError("临时缓存目录含其他文件，未移除") }
      for f in names {
        let u = temp.appendingPathComponent(f)
        let attrs = try u.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard attrs.isRegularFile == true, attrs.isSymbolicLink != true else {
          throw ServiceError("临时缓存内容异常，未移除")
        }
      }
      for f in names where f != marker { try fm.removeItem(at: temp.appendingPathComponent(f)) }
      try fm.removeItem(at: temp.appendingPathComponent(marker))
    }
    guard rmdir(temp.path) == 0 else { throw ServiceError("临时缓存目录尚有其他文件") }
  }
  static func bytesOnDisk(root: URL, token: String, components: [String], canonical: Bool) throws
    -> Int64
  {
    let pkg = try package(root, token)
    let changing = [
      work(pkg),
      pkg.deletingLastPathComponent().appendingPathComponent(
        ".pili-removing-" + pkg.lastPathComponent, isDirectory: true),
    ]
    var total: Int64 = 0
    if fm.fileExists(atPath: pkg.path) {
      let r = try verified(pkg, token: token, components: components, hash: nil, allowExtras: true)
      total += r.parts.values.reduce(Int64(0)) { $0 + $1.bytes }
    } else if canonical {
      throw ServiceError("缓存文件暂时不可访问")
    }
    let allowed = try Set(components.map(name))
    for dir in changing where fm.fileExists(atPath: dir.path) {
      try FolderAccessIO.requireDirectory(dir)
      let names = Set(try fm.contentsOfDirectory(atPath: dir.path))
      if names.isEmpty { continue }
      let marker = names.contains("work.json") ? "work.json" : "receipt.json"
      let receipt = try JSONDecoder().decode(
        Receipt.self, from: FolderAccessIO.readSmall(dir.appendingPathComponent(marker)))
      guard receipt.token == token && Set(receipt.parts.keys) == Set(components) else {
        throw ServiceError("临时缓存身份不匹配")
      }
      for name in names.intersection(allowed) {
        let info = try dir.appendingPathComponent(name).resourceValues(forKeys: [
          .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
        ])
        guard info.isRegularFile == true, info.isSymbolicLink != true else {
          throw ServiceError("临时缓存内容无效")
        }
        total += Int64(info.fileSize ?? 0)
      }
    }
    return total
  }
  static func publish(_ files: [String: URL], receipt: Receipt, root: URL, hash: @escaping Hasher)
    throws
  {
    let dest = try package(root, receipt.token)
    let temp = work(dest)
    try discardWork(temp, token: receipt.token, components: Array(files.keys))
    if fm.fileExists(atPath: dest.path) {
      guard
        try verified(dest, token: receipt.token, components: Array(files.keys), hash: hash)
          == receipt
      else { throw ServiceError("目标位置已有不同内容") }
      return
    }
    try fm.createDirectory(at: temp, withIntermediateDirectories: false)
    let marker = temp.appendingPathComponent("work.json")
    try JSONEncoder().encode(receipt).write(to: marker, options: .withoutOverwriting)
    defer { try? discardWork(temp, token: receipt.token, components: Array(files.keys)) }
    for (key, file) in files {
      try Task.checkCancellation()
      try fm.copyItem(at: file, to: temp.appendingPathComponent(try name(key)))
    }
    try fm.moveItem(at: marker, to: temp.appendingPathComponent("receipt.json"))
    guard
      try verified(temp, token: receipt.token, components: Array(files.keys), hash: hash) == receipt
    else { throw ServiceError("缓存复制不完整") }
    try fm.moveItem(at: temp, to: dest)
  }
  static func remove(_ pkg: URL, token: String, components: [String], hash: @escaping Hasher) throws
  {
    try discardWork(work(pkg), token: token, components: components)
    let removal = pkg.deletingLastPathComponent().appendingPathComponent(
      ".pili-removing-" + pkg.lastPathComponent, isDirectory: true)
    if fm.fileExists(atPath: pkg.path) {
      guard !fm.fileExists(atPath: removal.path) else { throw ServiceError("旧缓存尚未清理") }
      _ = try verified(pkg, token: token, components: components, hash: hash)
      try fm.moveItem(at: pkg, to: removal)
    }
    guard fm.fileExists(atPath: removal.path) else { return }
    try FolderAccessIO.requireDirectory(removal)
    let existing = Set(try fm.contentsOfDirectory(atPath: removal.path))
    if !existing.isEmpty {
      let marker = removal.appendingPathComponent("receipt.json")
      let receipt = try JSONDecoder().decode(Receipt.self, from: FolderAccessIO.readSmall(marker))
      guard receipt.token == token, Set(receipt.parts.keys) == Set(components),
        existing.isSubset(of: try Set(components.map(name)).union(["receipt.json"]))
      else { throw ServiceError("缓存目录含其他文件，未移除") }
      for part in components {
        let basename = try name(part)
        if existing.contains(basename) {
          let url = removal.appendingPathComponent(basename)
          guard try size(url) == receipt.parts[part]?.bytes,
            try hash(url) == receipt.parts[part]?.hash
          else { throw ServiceError("缓存内容已变化，未移除") }
        }
      }
      for part in components {
        let basename = try name(part)
        if existing.contains(basename) {
          try fm.removeItem(at: removal.appendingPathComponent(basename))
        }
      }
      try fm.removeItem(at: marker)
    }
    guard rmdir(removal.path) == 0 else { throw ServiceError("缓存目录尚有其他文件") }

  }
}
