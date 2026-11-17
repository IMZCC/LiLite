import Foundation
import ZIPFoundation

public struct ArchiveIssue: LocalizedError {
  public let errorDescription: String?
  public init(_ message: String) { errorDescription = message }
}
public struct PortableArchive {
  public static let limit = 64 * 1024 * 1024
  public static let memberNames: Set<String> = [
    "setting.json", "account.json", "blacklist.json", "reply.json", "search.json", "customFont.otf",
  ]
  public let parts: [String: Data], platform: String?, version: Int
  public let sourceApp: String?, sourceVersion: String?, sourceBuild: Int?, exportedAt: String?
  public let replyOwner: String?, accountRoutes: [String: String]?
  public init(read data: Data) throws {
    guard !data.isEmpty && data.count <= Self.limit else { throw ArchiveIssue("数据包过大或为空") }
    let zip = try Archive(data: data, accessMode: .read)
    var members: [String: Data] = [:]
    var total: UInt64 = 0
    var n = 0
    var seen = Set<String>()
    for entry in zip {
      n += 1
      guard n <= 128, entry.uncompressedSize <= UInt64(Self.limit) - total else {
        throw ArchiveIssue("数据包超出大小限制")
      }
      total += entry.uncompressedSize
      let name = entry.path
      guard seen.insert(name).inserted else { throw ArchiveIssue("数据包含重复文件") }
      guard name == "meta.json" || Self.memberNames.contains(name) else { continue }
      guard entry.type == .file else { throw ArchiveIssue("数据包文件类型无效") }
      var bytes = Data()
      let crc = try zip.extract(entry) { chunk in
        guard UInt64(bytes.count + chunk.count) <= entry.uncompressedSize else {
          throw ArchiveIssue("数据包文件大小不符")
        }
        bytes.append(chunk)
      }
      guard crc == entry.checksum, bytes.count == entry.uncompressedSize else {
        throw ArchiveIssue("数据包内容校验失败")
      }
      members[name] = bytes
    }
    guard let info = members.removeValue(forKey: "meta.json") else {
      throw ArchiveIssue("不是 PiliPlus 数据包")
    }
    let meta = try JSONDecoder().decode(Meta.self, from: info)
    guard meta.type == "data_archive", (meta.formatVersion >> 16) == 1 else {
      throw ArchiveIssue("不支持的数据包版本")
    }
    if let files = meta.files {
      guard files.count == Set(files).count, Set(files).isSubset(of: seen),
        Set(files).intersection(Self.memberNames) == Set(members.keys)
      else { throw ArchiveIssue("数据包缺少清单中的文件") }
    }
    guard !members.isEmpty else { throw ArchiveIssue("数据包中没有可恢复的内容") }
    if let owner = meta.piliNativeReplyOwner {
      guard let n = Int64(owner), n > 0, String(n) == owner, members["reply.json"] != nil else {
        throw ArchiveIssue("评论归属无效")
      }
    }
    if let routes = meta.piliNativeAccountRoutes {
      guard members["account.json"] != nil, Set(routes.keys) == ["0", "1", "2", "3"],
        routes.values.allSatisfy({
          $0.isEmpty || $0 == "$main" || (Int64($0).map { $0 > 0 } ?? false)
        })
      else { throw ArchiveIssue("账号角色无效") }
    }
    replyOwner = meta.piliNativeReplyOwner
    accountRoutes = meta.piliNativeAccountRoutes
    sourceApp = meta.appName
    sourceVersion = meta.versionName
    sourceBuild = meta.versionCode?.value
    exportedAt = meta.exportTime
    parts = members
    platform = meta.platform
    version = meta.formatVersion
  }
  private struct BuildCode: Codable {
    var value: Int?
    init(_ v: Int) { value = v }
    init(from decoder: Decoder) throws {
      let c = try decoder.singleValueContainer()
      if let n = try? c.decode(Int.self) {
        value = n
      } else {
        value = (try? c.decode(String.self)).flatMap(Int.init)
      }
    }
    func encode(to encoder: Encoder) throws {
      var c = encoder.singleValueContainer()
      try c.encode(value)
    }
  }
  private struct Meta: Codable {
    let type: String, formatVersion: Int
    let appName: String?, versionName: String?, platform: String?, exportTime: String?,
      files: [String]?
    var versionCode: BuildCode? = nil
    var piliNativeReplyOwner: String? = nil
    var piliNativeAccountRoutes: [String: String]? = nil
  }
  public static func make(
    _ parts: [String: Data], platform: String, versionName: String, versionCode: Int? = nil,
    replyOwner: String? = nil, routes: [String: String]? = nil
  ) throws
    -> Data
  {
    guard !parts.isEmpty, Set(parts.keys).isSubset(of: memberNames) else {
      throw ArchiveIssue("数据包文件无效")
    }
    let meta = Meta(
      type: "data_archive", formatVersion: 1 << 16, appName: "PiliPlus", versionName: versionName,
      platform: platform,
      exportTime: ISO8601DateFormatter().string(from: Date()), files: parts.keys.sorted(),
      versionCode: versionCode.map(BuildCode.init), piliNativeReplyOwner: replyOwner,
      piliNativeAccountRoutes: routes)
    var entries = parts
    entries["meta.json"] = try JSONEncoder().encode(meta)
    let zip = try Archive(accessMode: .create)
    var total = 0
    for name in entries.keys.sorted() {
      let data = entries[name]!
      guard data.count <= limit - total else { throw ArchiveIssue("数据包超过 64 MB") }
      total += data.count
      try zip.addEntry(
        with: name, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate
      ) { offset, size in
        let i = Int(offset)
        guard i >= 0, i <= data.count, size >= 0 else { throw ArchiveIssue("数据包写入失败") }
        return data.subdata(in: i..<i + min(size, data.count - i))
      }
    }
    guard let bytes = zip.data, bytes.count <= limit else { throw ArchiveIssue("无法生成数据包") }
    return bytes
  }
}
