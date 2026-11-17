import Foundation

enum FolderAccessIO {
  static func requireDirectory(_ url: URL) throws {
    let r = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard r.isDirectory == true && r.isSymbolicLink != true else { throw ServiceError("文件夹不可用") }
  }
  static func readSmall(_ url: URL) throws -> Data {
    let r = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
    guard r.isRegularFile == true && r.isSymbolicLink != true && (r.fileSize ?? Int.max) <= 65536
    else { throw ServiceError("文件标识无效") }
    return try Data(contentsOf: url)
  }
}
