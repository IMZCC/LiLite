import Foundation

@main enum OfflineResumeCheck {
  static func reject(_ f: () throws -> Void) {
    do {
      try f()
      preconditionFailure("unexpected success")
    } catch {}
  }
  @MainActor static func main() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "pili-resume-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let bv = "BV1fK4y1t7hj"
    let cid: Int64 = 196_018_899
    let fm = FileManager.default
    var a = OfflineVideo(bvid: bv, cid: cid, title: "稿件", part: "一")
    var b = a
    var c = a
    a.scoped = true
    a.cacheOwner = "42"
    b.scoped = true
    b.cacheOwner = "77"
    c.scoped = true
    c.cacheOwner = ""
    let old = OfflineVideo(bvid: bv, cid: cid, title: "旧任务", part: "")
    precondition(
      Set([a.id, b.id, c.id, old.id]).count == 4 && a.sealsMedia && !c.sealsMedia
        && !old.matchesOwner(""))
    precondition(
      a.matchesOwner("42") && !a.visible(to: "77") && !a.matchesOwner("") && old.visible(to: "42"))
    precondition([a, b, c, old].allSatisfy { OfflinePackage.validToken($0.token) })
    a.cacheOwner = "../outside"
    precondition(!a.validScope && !OfflinePackage.validToken(a.token))
    var archiveRow = b
    archiveRow.phase = .saved
    archiveRow.uploader = "等风来"
    archiveRow.collectionTitle = "现场合集"
    var waiting = archiveRow
    precondition(
      OfflineShelfFilter.rows([archiveRow], search: " 等风 ", shelf: 0, owner: "77").count == 1)
    precondition(OfflineShelfFilter.rows([archiveRow], search: "现场", shelf: 0, owner: "42").isEmpty)
    waiting.phase = .transferring
    precondition(
      OfflineShelfFilter.rows([waiting], search: "等风", shelf: 0, owner: "77").isEmpty
        && OfflineShelfFilter.rows([waiting], search: "等风", shelf: 2, owner: "77").count == 1)
    let fixture = root.appendingPathComponent("legacy")
    let good = fixture.appendingPathComponent("883362563/c_196018899")
    let bad = fixture.appendingPathComponent("883362563/c_222")
    try fm.createDirectory(at: good, withIntermediateDirectories: true)
    try fm.createDirectory(at: bad, withIntermediateDirectories: true)
    let oldData: [String: Any] = [
      "avid": 883_362_563, "bvid": bv, "title": "以前的音轨", "prefered_video_quality": 64,
      "is_completed": true, "page_data": ["cid": cid, "page": 1, "part": "P1"],
    ]
    let bytes = try JSONSerialization.data(withJSONObject: oldData)
    for u in [good, bad] { try bytes.write(to: u.appendingPathComponent("entry.json")) }
    let report = try LegacyCacheCatalog.scan(fixture)
    precondition(report.items.count == 1 && report.skipped == 1)
    let restored = report.items[0].row(owner: "42")
    precondition(
      restored.scoped == true && restored.cacheOwner == "42" && restored.cid == cid
        && restored.quality == 64)
    var course = b
    var season = b
    course.episode = .init(id: 123, course: true)
    season.episode = .init(id: 123, course: false)
    precondition(
      Set([course.id, season.id, b.id]).count == 3 && OfflinePackage.validToken(course.token)
        && OfflinePackage.validToken(season.token))
    let index = root.appendingPathComponent("index.json")
    try OfflineIndexStore.save([course, season], index)
    try Data("bad".utf8).write(to: index)
    let recovered = try OfflineIndexStore.load(index)
    precondition(recovered.recovered && recovered.rows.map(\.id) == [course.id, season.id])
    let keep = try FileManager.default.contentsOfDirectory(
      at: root, includingPropertiesForKeys: nil)
    precondition(keep.contains { $0.lastPathComponent.hasPrefix("index.damaged.") })
    let w = OfflinePieces(base: root.appendingPathComponent("payload"), identity: "rendition-one")
    let file = root.appendingPathComponent("incoming")
    var data = Data((0..<160).map { UInt8($0 % 251) })
    data.replaceSubrange(4..<8, with: Data("ftyp".utf8))
    func slice(_ start: Int, _ n: Int, _ tag: String? = "\"version1\"") -> OfflinePieces.Slice {
      .init(
        range: "bytes \(start)-\(start+n-1)/160", requested: "bytes=\(start)-\(start+n-1)",
        expected: Int64(n), etag: tag)!
    }
    try data[0..<64].write(to: file)
    guard case .more = try w.accept(file, slice(0, 64)) else { fatalError() }
    let state = w.state()!
    precondition(
      state.committed == 64 && w.request(state) == "bytes=64-159"
        && state.validator == "\"version1\"")
    precondition(OfflinePieces(base: w.base, identity: "other-encoding").state() == nil)
    let tail = try FileHandle(forWritingTo: w.partial)
    try tail.seekToEnd()
    try tail.write(contentsOf: Data([7, 8, 9]))
    try tail.close()
    try data[64..<128].write(to: file)
    reject { _ = try w.accept(file, slice(64, 64, "\"version2\"")) }
    precondition(w.state()?.committed == 64)
    guard case .more = try w.accept(file, slice(64, 64)) else { fatalError() }
    try data[128..<160].write(to: file)
    guard case .complete = try w.accept(file, slice(128, 32)) else { fatalError() }
    let actual = try Data(contentsOf: w.partial)
    precondition(actual == data && w.state()?.committed == 160)
    try w.clear()
    try data[0..<64].write(to: file)
    guard case .whole = try w.accept(file, slice(0, 64, "W/\"v\"")) else { fatalError() }
    precondition(!fm.fileExists(atPath: w.partial.path))
    precondition(
      OfflinePieces.Slice(
        range: "bytes 1-64/160", requested: "bytes=0-63", expected: 64, etag: "\"ok\"") == nil)
    precondition(
      OfflinePieces.Slice(
        range: "bytes 64-127/160", requested: "bytes=64-127", expected: 65, etag: "\"ok\"") == nil)
    let suite = "pili-watch-test-" + UUID().uuidString
    let d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    OfflineWatchBook.store("v", viewer: "42", seconds: 12.3, duration: 30, defaults: d)
    precondition(
      OfflineWatchBook.read("v", viewer: "42", defaults: d)?.start == 12.3
        && OfflineWatchBook.read("v", viewer: "77", defaults: d) == nil)
    OfflineWatchBook.store("v", viewer: "42", seconds: 29.59, duration: 30, defaults: d)
    precondition(OfflineWatchBook.read("v", viewer: "42", defaults: d)?.completed == false)
    OfflineWatchBook.store("v", viewer: "42", seconds: 29.6, duration: 30, defaults: d)
    precondition(OfflineWatchBook.read("v", viewer: "42", defaults: d)?.start == 0)
    OfflineWatchBook.store("v", viewer: "77", seconds: 10, duration: 40, defaults: d)
    d.set(false, forKey: "play.remember")
    precondition(OfflineWatchBook.read("v", viewer: "42", defaults: d) == nil)
    d.set(true, forKey: "play.remember")
    OfflineWatchBook.remove("v", defaults: d)
    precondition(
      OfflineWatchBook.read("v", viewer: "77", defaults: d) == nil
        && OfflineWatchBook.read("v", viewer: "42", defaults: d) == nil)
    func archive(_ right: Int?, _ deny: Int? = nil) -> ArchiveCacheDetails {
      .init(
        bvid: bv, cid: cid, pages: [.init(cid: 2)],
        rights: .init(download: right, no_download: deny))
    }
    try archive(1).authorize(bv, cid: 2)
    reject { try archive(0).authorize(bv, cid: cid) }
    reject { try archive(nil).authorize(bv, cid: cid) }
    reject { try archive(1, 1).authorize(bv, cid: cid) }
    reject { try archive(1).authorize(bv, cid: 999) }
    print(
      "PASS scoped packages, exact grants, unknown legacy ownership, durable range/validator/length and crash tail, per-viewer offline history and delete"
    )
    if CommandLine.arguments.contains("--live") {
      let q = try await PublicProbe.signed(["bvid": bv])
      let meta = try await PublicProbe.get(
        "api.bilibili.com", "/x/web-interface/wbi/view", q, ArchiveCacheDetails.self)
      print(
        "Anonymous regular metadata: BV", meta.bvid, "CID", meta.cid ?? 0, "rights.download",
        meta.rights?.download as Any)
      try meta.authorize(bv, cid: cid)
      print("Public metadata explicitly permits this part; media has not been downloaded")
    }
  }
}
