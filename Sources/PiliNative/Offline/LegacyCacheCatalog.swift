import Foundation

/// Only descriptive entry.json is read. Old CDN URLs, headers and paths inside it are never used.
enum LegacyCacheCatalog {
  struct Item: Identifiable {
    let bvid: String, aid: Int64, cid: Int64, title: String, part: String, quality: Int?,
      audio: Int?, episode: EpisodeResource?, order: Int?, duration: Int?, complete: Bool
    var id: String { "\(bvid):\(cid):\(episode?.id ?? 0)" }
    func row(owner: String) -> OfflineVideo {
      var v = OfflineVideo(bvid: bvid, cid: cid, title: title, part: part)
      v.episode = episode
      v.aid = aid
      v.cacheOwner = owner
      v.scoped = true
      v.quality = quality
      v.audioQuality = audio
      v.seconds = duration
      v.includeExtras = true
      v.pageOrder = order
      return v
    }
  }
  struct Scan {
    let items: [Item]
    let skipped: Int
  }
  private struct Record: Decodable {
    struct Page: Decodable { let cid: Int64, part: String?, page: Int? }
    struct Source: Decodable { let cid: Int64 }
    struct Episode: Decodable {
      let episode_id: Int64, from: String?, show_title: String?, index_title: String?,
        sort_index: Int?
    }
    let avid: Int64, bvid: String?, title: String, prefered_video_quality: Int?,
      prefered_audio_quality: Int?, is_completed: Bool, total_time_milli: Int64?, page_data: Page?,
      source: Source?, ep: Episode?
  }
  static func scan(_ root: URL) throws -> Scan {
    let fm = FileManager.default
    try FolderAccessIO.requireDirectory(root)
    func folders(_ url: URL) throws -> [URL] {
      try fm.contentsOfDirectory(
        at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
        options: .skipsHiddenFiles
      ).filter { u in
        let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return v?.isDirectory == true && v?.isSymbolicLink == false
      }
    }
    func number(_ text: Substring) -> Int64? {
      guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let n = Int64(text),
        n > 0
      else { return nil }
      return n
    }
    var out = [Item]()
    var seen = Set<String>()
    var skipped = 0
    var scanned = 0
    for group in try folders(root) {
      try Task.checkCancellation()
      let name = group.lastPathComponent
      let series = name.hasPrefix("s_")
      guard let outer = number(series ? name.dropFirst(2) : name[...]) else { continue }
      for child in try folders(group) {
        try Task.checkCancellation()
        let token = child.lastPathComponent
        guard series || token.hasPrefix("c_"),
          let inner = number(series ? token[...] : token.dropFirst(2))
        else { continue }
        scanned += 1
        guard scanned <= 20000 else { throw ServiceError("缓存条目过多，请分批选择文件夹") }
        do {
          let u = child.appendingPathComponent("entry.json")
          // An upstream entry can include a long segment listing; read only a bounded regular file.
          let values = try u.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
          ])
          guard values.isRegularFile == true, values.isSymbolicLink == false,
            let n = values.fileSize, n > 0, n <= 2 * 1024 * 1024
          else { throw ServiceError("旧缓存清单无效") }
          let raw = try JSONDecoder().decode(Record.self, from: Data(contentsOf: u))
          guard raw.avid > 0, let bv = ArchiveNumber.bv(raw.avid),
            (raw.bvid ?? "").isEmpty || raw.bvid == bv
          else { throw ServiceError("旧缓存稿件不符") }
          let cid: Int64
          let ep: EpisodeResource?
          let part: String
          let order: Int?
          if series {
            guard let e = raw.ep, e.episode_id == inner, let source = raw.source, source.cid > 0
            else { throw ServiceError("旧缓存剧集不符") }
            cid = source.cid
            ep = .init(id: e.episode_id, course: e.from == "pugv")
            part = e.show_title ?? e.index_title ?? raw.title
            order = e.sort_index
          } else {
            guard outer == raw.avid, let p = raw.page_data, p.cid == inner, raw.ep == nil else {
              throw ServiceError("旧缓存分 P 不符")
            }
            cid = p.cid
            ep = nil
            part = p.part ?? raw.title
            order = p.page
          }
          let millis = raw.total_time_milli ?? 0
          let item = Item(
            bvid: bv, aid: raw.avid, cid: cid, title: String(raw.title.prefix(512)),
            part: String(part.prefix(512)),
            quality: raw.prefered_video_quality.flatMap { $0 > 0 ? $0 : nil },
            audio: raw.prefered_audio_quality.flatMap { $0 > 0 ? $0 : nil }, episode: ep,
            order: order, duration: millis > 0 ? Int(exactly: millis / 1000) : nil,
            complete: raw.is_completed)
          if seen.insert(item.id).inserted { out.append(item) }
        } catch { skipped += 1 }
      }
    }
    return .init(
      items: out.sorted { ($0.title, $0.order ?? 0, $0.cid) < ($1.title, $1.order ?? 0, $1.cid) },
      skipped: skipped)
  }
}
