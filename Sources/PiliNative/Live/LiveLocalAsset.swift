import Foundation

struct LiveLocalAsset {
  let name: String, mime: String
  init?(target: Substring, secret: String) {
    let path =
      target.split(separator: "?", maxSplits: 1).first?.split(
        separator: "/", omittingEmptySubsequences: false) ?? []
    guard path.count == 3, path[0].isEmpty, path[1] == Substring(secret) else { return nil }
    name = String(path[2])
    switch name {
    case "index.m3u8": mime = "application/vnd.apple.mpegurl"
    case "init.mp4": mime = "video/mp4"
    default:
      guard (16...19).contains(name.utf8.count), name.hasPrefix("part"), name.hasSuffix(".m4s"),
        name.dropFirst(4).dropLast(4).utf8.allSatisfy({ (48...57).contains($0) })
      else { return nil }
      mime = "video/mp4"
    }
  }
}
