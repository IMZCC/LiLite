import CryptoKit
import Foundation

/// External providers remain the canonical cache. A temporary coordinated playback snapshot
/// lets AVFoundation seek asynchronously after the provider's read accessor has returned.
final class OfflinePlaybackFiles: @unchecked Sendable {
  let files: [String: URL], temporary: URL?
  init(_ files: [String: URL], temporary: URL? = nil) {
    self.files = files
    self.temporary = temporary
  }
  deinit { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
}
actor OfflineMediaStore {
  static let shared = OfflineMediaStore()
  private let fm = FileManager.default
  private var swept = false
  private func sweepTransientFiles() {
    guard !swept else { return }
    swept = true
    let temp = fm.temporaryDirectory
    guard
      let rows = try? fm.contentsOfDirectory(
        at: temp, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    else { return }
    for row in rows {
      let name = row.lastPathComponent
      let prefixes = ["pili-offline-read-", "pili-offline-seal-"]
      guard let prefix = prefixes.first(where: { name.hasPrefix($0) }),
        UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
        let props = try? row.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
        props.isDirectory == true, props.isSymbolicLink != true
      else { continue }
      try? fm.removeItem(at: row)
    }
  }
  static func local(_ v: OfflineVideo, _ c: String, app: URL) -> URL {
    if LegacyMediaComponents.isPart(c) { return app.appendingPathComponent(v.id + "." + c + ".mp4") }
    return app.appendingPathComponent(
      v.id + (c == "movie" ? ".mp4" : c == "audio" ? ".audio.m4a" : ".video.mp4"))
  }
  static func digest(_ u: URL) throws -> String {
    let f = try FileHandle(forReadingFrom: u)
    defer { try? f.close() }
    var dig = SHA256()
    while let bytes = try f.read(upToCount: 1 << 20), !bytes.isEmpty {
      try Task.checkCancellation()
      dig.update(data: bytes)
    }
    return dig.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private static func appFiles(_ row: OfflineVideo, _ dir: URL) -> [String: URL] {
    Dictionary(uniqueKeysWithValues: Set(row.components).map { ($0, local(row, $0, app: dir)) })
  }
  private static func external(_ part: String, _ row: OfflineVideo) -> String {
    row.sealsMedia ? "bound-" + part : part
  }
  private static func boundAccount(_ row: OfflineVideo) async throws {
    do {
      guard let id = row.cacheOwner,
        (try await AccountJar.shared.localOwner(.role(.video)) ?? "") == id
      else {
        throw ServiceError("请切换到缓存这集时使用的视频账号")
      }
    }
  }
  func files(_ row: OfflineVideo, app: URL, pinLocal: Bool = false) async throws
    -> OfflinePlaybackFiles
  {
    sweepTransientFiles()
    try await Self.boundAccount(row)
    switch row.location {
    case .app:
      let files = Self.appFiles(row, app)
      for f in files.values { _ = try OfflinePackage.size(f) }
      guard pinLocal else { return OfflinePlaybackFiles(files) }
      let dir = fm.temporaryDirectory.appendingPathComponent(
        "pili-offline-read-" + UUID().uuidString, isDirectory: true)
      try fm.createDirectory(at: dir, withIntermediateDirectories: false)
      do {
        var result: [String: URL] = [:]
        for (key, u) in files {
          let out = dir.appendingPathComponent(try OfflinePackage.name(key))
          do { try fm.linkItem(at: u, to: out) } catch { try fm.copyItem(at: u, to: out) }
          result[key] = out
        }
        return OfflinePlaybackFiles(result, temporary: dir)
      } catch {
        try? fm.removeItem(at: dir)
        throw error
      }
    case .folder(let root):
      try await Self.boundAccount(row)
      let master = !row.sealsMedia ? nil : try OfflineSealedTrack.deviceKey(create: false)
      return try await FolderGrants.shared.withFolder(root, writing: false) { authorized in
        guard let library = try OfflinePackage.folder(authorized, id: root, create: false) else {
          throw ServiceError("找不到缓存目录")
        }
        let package = try OfflinePackage.package(library, row.token)
        let receipt = try OfflinePackage.verified(
          package, token: row.token, components: row.components.map { Self.external($0, row) },
          hash: nil, allowExtras: true)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(
          "pili-offline-read-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        do {
          var result: [String: URL] = [:]
          for k in row.components {
            try Task.checkCancellation()
            let externalKey = Self.external(k, row)
            let source = package.appendingPathComponent(try OfflinePackage.name(externalKey))
            let dest = dir.appendingPathComponent(try OfflinePackage.name(k))
            if let master {
              _ = try OfflineSealedTrack.open(
                source, to: dest, key: master, context: OfflineSealedTrack.context(row, k))
            } else {
              try FileManager.default.copyItem(at: source, to: dest)
              guard try OfflinePackage.size(dest) == receipt.parts[k]?.bytes,
                try Self.digest(dest) == receipt.parts[k]?.hash
              else { throw ServiceError("媒体内容校验失败") }
            }
            result[k] = dest
          }
          return OfflinePlaybackFiles(result, temporary: dir)
        } catch {
          try? FileManager.default.removeItem(at: dir)
          throw error
        }
      }
    }
  }
  func copy(_ row: OfflineVideo, to target: OfflinePlace, app: URL) async throws -> [String:String] {
    try await Self.boundAccount(row)
    let read = try await files(row, app: app)
    defer { withExtendedLifetime(read) {} }
    let sources = read.files
    let receipt = try OfflinePackage.describe(row.token, files: sources, hash: Self.digest)
    switch target {
    case .folder(let id):
      let master = !row.sealsMedia ? nil : try OfflineSealedTrack.deviceKey(create: true)
      var stage: URL?
      defer { if let stage { try? fm.removeItem(at: stage) } }
      var storeFiles = sources
      var storedReceipt = receipt
      if let master {
        let dir = fm.temporaryDirectory.appendingPathComponent(
          "pili-offline-seal-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        stage = dir
        storeFiles = [:]
        for (part, u) in sources {
          let key = Self.external(part, row)
          let out = dir.appendingPathComponent(try OfflinePackage.name(key))
          try OfflineSealedTrack.seal(
            u, to: out, key: master, context: OfflineSealedTrack.context(row, part))
          guard
            try OfflineSealedTrack.open(
              out, to: nil, key: master, context: OfflineSealedTrack.context(row, part))
              == receipt.parts[part]?.hash
          else { throw ServiceError("账号缓存封装失败") }
          storeFiles[key] = out
        }
        storedReceipt = try OfflinePackage.describe(row.token, files: storeFiles, hash: Self.digest)
      }
      let publishedFiles = storeFiles
      let manifest = storedReceipt
      try await FolderGrants.shared.withFolder(id, writing: true) { authorized in
        guard let root = try OfflinePackage.folder(authorized, id: id, create: true) else {
          throw ServiceError("无法创建缓存目录")
        }
        let pkg = try OfflinePackage.package(root, row.token)
        if let master, FileManager.default.fileExists(atPath: pkg.path) {
          // Retrying after an interrupted commit: random GCM nonces can differ. Authenticate the
          // previous payload and compare its plaintext with the source before releasing the original.
          _ = try OfflinePackage.verified(
            pkg, token: row.token, components: Array(publishedFiles.keys), hash: Self.digest)
          for part in row.components {
            let u = pkg.appendingPathComponent(try OfflinePackage.name(Self.external(part, row)))
            guard
              try OfflineSealedTrack.open(
                u, to: nil, key: master, context: OfflineSealedTrack.context(row, part))
                == receipt.parts[part]?.hash
            else { throw ServiceError("目标位置已有不同的账号缓存") }
          }
        } else {
          try OfflinePackage.publish(
            publishedFiles, receipt: manifest, root: root, hash: Self.digest)
        }
      }
    case .app:
      for (part, src) in sources {
        try Task.checkCancellation()
        let dst = Self.local(row, part, app: app)
        if fm.fileExists(atPath: dst.path) {
          guard try Self.digest(dst) == receipt.parts[part]?.hash else {
            throw ServiceError("应用目录已有同名媒体")
          }
        } else {
          let temp = app.appendingPathComponent(".incoming-" + UUID().uuidString)
          defer { try? fm.removeItem(at: temp) }
          try fm.copyItem(at: src, to: temp)
          guard try Self.digest(temp) == receipt.parts[part]?.hash else {
            throw ServiceError("缓存复制不完整")
          }
          try fm.moveItem(at: temp, to: dst)
        }
      }
    }
    return receipt.parts.mapValues(\.hash)
  }
  func hashes(at place: OfflinePlace, row: OfflineVideo, app: URL) async throws -> [String:String] {
    try await Self.boundAccount(row)
    switch place {
    case .app:
      return try OfflinePackage.describe(row.token, files: Self.appFiles(row, app), hash: Self.digest).parts.mapValues(\.hash)
    case let .folder(id):
      let master = !row.sealsMedia ? nil : try OfflineSealedTrack.deviceKey(create: false)
      return try await FolderGrants.shared.withFolder(id, writing: false) { authorized in
        guard let root = try OfflinePackage.folder(authorized, id: id, create: false) else { throw ServiceError("找不到缓存目录") }
        let pkg = try OfflinePackage.package(root, row.token)
        let valid = try OfflinePackage.verified(pkg, token: row.token, components: row.components.map { Self.external($0,row) },
          hash: master == nil ? Self.digest : nil)
        guard let master else { return valid.parts.mapValues(\.hash) }
        var actual = [String:String]()
        for component in row.components {
          let file = pkg.appendingPathComponent(try OfflinePackage.name(Self.external(component,row)))
          actual[component] = try OfflineSealedTrack.open(file, to:nil, key:master, context:OfflineSealedTrack.context(row,component))
        }
        return actual
      }
    }
  }
  func retire(_ old: OfflinePlace, row: OfflineVideo, app: URL) async throws {
    guard let owner = row.cacheOwner, old != row.location else { throw ServiceError("缓存位置无效") }
    let authority = try await hashes(at: row.location, row: row, app: app)
    let proof: [String:String]
    if let saved = row.retirementHashes { proof = saved }
    else {
      // Older on-disk transactions have no recorded digest. Compare both copies before retiring one.
      if try await size(old, row: row, app: app) == 0 { return }
      proof = try await hashes(at: old, row: row, app: app)
    }
    try OfflinePackage.requireAuthority(authority, proof: proof, components: row.components)
    try await erase(old, row: row, app: app, expectedOwner: owner)
  }
  func erase(_ place: OfflinePlace, row: OfflineVideo, app: URL, expectedOwner: String) async throws {
    guard row.visible(to: expectedOwner), (try await AccountJar.shared.localOwner(.role(.video)) ?? "") == expectedOwner
    else { throw ServiceError("视频账号已切换") }
    switch place {
    case .folder(let id):
      try await FolderGrants.shared.withFolder(id, writing: true) { authorized in
        guard let root = try OfflinePackage.folder(authorized, id: id, create: false) else {
          return
        }
        try OfflinePackage.remove(
          try OfflinePackage.package(root, row.token), token: row.token,
          components: row.components.map { Self.external($0, row) },
          hash: Self.digest)
      }
    case .app:
      for v in Self.appFiles(row, app).values where fm.fileExists(atPath: v.path) {
        try fm.removeItem(at: v)
      }
    }
  }
  func size(_ place: OfflinePlace, row: OfflineVideo, app: URL) async throws -> Int64 {
    switch place {
    case .app:
      return try Self.appFiles(row, app).values.filter { fm.fileExists(atPath: $0.path) }.reduce(
        Int64(0)
      ) { try $0 + OfflinePackage.size($1) }
    case .folder(let id):
      return try await FolderGrants.shared.withFolder(id, writing: false) { authorized in
        let canonical = row.location == place && row.phase == .saved
        guard let library = try OfflinePackage.folder(authorized, id: id, create: false) else {
          if canonical { throw ServiceError("找不到缓存目录") }
          return 0
        }
        return try OfflinePackage.bytesOnDisk(
          root: library, token: row.token,
          components: row.components.map { Self.external($0, row) }, canonical: canonical)
      }
    }
  }
  func extrasSize(_ dir: URL) -> Int64 {
    guard
      let e = fm.enumerator(
        at: dir, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
        options: [.skipsHiddenFiles])
    else { return 0 }
    var n: Int64 = 0
    for case let url as URL in e {
      guard
        let r = try? url.resourceValues(forKeys: [
          .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
        ])
      else { continue }
      if r.isSymbolicLink == true {
        e.skipDescendants()
      } else if r.isRegularFile == true {
        n += Int64(r.fileSize ?? 0)
      }
    }
    return n
  }
}
