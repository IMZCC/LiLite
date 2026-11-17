import Foundation

@main enum PersonalLibraryCheck {
  static func rejected(_ op: () throws -> Void) { do { try op(); fatalError("accepted") } catch {} }
  static func main() async throws {
    let suite = "Pili.Library.Fixture." + UUID().uuidString, d = UserDefaults(suiteName: suite)!
    defer { d.removePersistentDomain(forName: suite) }
    var rules = RecommendationRules()
    rules.blockedCreators = [101]; rules.titlePattern = "fixture"; try rules.save(d)
    let ids = try LocalCreatorBlockFile.decode(Data("[101,202,202,9223372036854775807]".utf8))
    var n = try LocalCreatorBlockFile.merge(ids, defaults: d)
    precondition(n == 2)
    let bytes = try LocalCreatorBlockFile.encode(RecommendationRules.current(d).blockedCreators)
    n = try LocalCreatorBlockFile.merge(try LocalCreatorBlockFile.decode(bytes), defaults: d)
    precondition(n == 0 && RecommendationRules.current(d).titlePattern == "fixture")
    let expected: Set<Int64> = [101,202,Int64.max]
    precondition(RecommendationRules.current(d).blockedCreators == expected)
    for text in ["[1,true]","[12,-1]","[0]","42","[9223372036854775808]"] {
      rejected { _ = try LocalCreatorBlockFile.merge(LocalCreatorBlockFile.decode(Data(text.utf8)), defaults: d) }
      precondition(RecommendationRules.current(d).blockedCreators == expected)
    }
    for tag in [0,-2,-10] { rejected { _ = try FollowGroupCommand(.remove(tag), owner:"10") } }
    rejected { _ = try FollowGroupCommand(.order([4,4]),owner:"10") }
    rejected { _ = try FollowGroupCommand(.rename(4,String(repeating:"字",count:17)),owner:"10") }
    let rows = ["29:2","9:2","42:12","9:2"]
    let chosen = Set(["29:2","9:2","42:12"])
    let transferred = try LibraryCheckedOrder.items(display: rows, selected: chosen, movingFavorite: true)
    let removed = try LibraryCheckedOrder.items(display: rows, selected: chosen, movingFavorite: false)
    precondition(transferred == ["42:12","9:2","29:2"] && removed == ["29:2","9:2","42:12"])
    rejected { _ = try LibraryCheckedOrder.items(display: rows, selected: ["8:12"], movingFavorite: true) }
    func target(_ uri: String = "", _ redirect: String = "", _ course: Bool = false, _ cid: Int64 = 33) -> SharedLink? {
      SpaceArchiveTarget.resolve(bvid: "BVfixture", cid: cid, course: course, uri: uri, redirect: redirect)
    }
    precondition(target() == .archivePart(.video("BVfixture", nil), 33))
    precondition(target("", "", false, 0) == .video("BVfixture", nil))
    precondition(target("bilibili://cheese/play/ep72", "", true) == .course(72, true))
    precondition(target("", "https://www.bilibili.com/bangumi/play/ss8") == .season(8))
    for bad in ["https://example.invalid/play/ep9", "bilibili://unexpected/play/ep42", "https://bad@www.bilibili.com/cheese/play/ep9", ""] {
      precondition(target(bad, "", true) == nil)
    }
    let archive = ArchiveNumber.bv(170001)!
    precondition(ArchiveSeasonSubscription(item: 2, catalog: 3, bvid: archive, owner: "10") == nil)
    let subscription = ArchiveSeasonSubscription(item: 44, catalog: 44, bvid: archive, owner: "10")!
    var writes = 0
    do { _ = try await subscription.toggle(wasFollowing:false,active:"20") { _, _, _ in writes += 1 }; fatalError("old intent leaked") }
    catch { precondition(writes == 0) }
    let on = try await subscription.toggle(wasFollowing:false,active:"10") { path,f,uid in
      writes += 1; precondition(path == "/x/v3/fav/season/fav" && f == ["platform":"web","season_id":"44"] && uid == "10")
    }
    precondition(on)
    do { _ = try await subscription.toggle(wasFollowing:true,active:"10") { path,_,_ in
      writes += 1; precondition(path == "/x/v3/fav/season/unfav"); throw ServiceError("fixture")
    }; fatalError("unconfirmed unsubscribe") } catch { precondition(writes == 2) }
    let rename = try FollowGroupCommand(.rename(9," 科学 "),owner:"10")
    var calls = [(String,[String:String],String)]()
    do {
      try await rename.apply(active:"20") { path,fields,uid in calls.append((path,fields,uid)) }
      fatalError("submitted old user's group")
    } catch { precondition(calls.isEmpty) }
    try await rename.apply(active:"10") { path,fields,uid in calls.append((path,fields,uid)) }
    precondition(calls.count == 1 && calls[0].0 == "/x/relation/tag/update" && calls[0].1 == ["tagid":"9","name":"科学"] && calls[0].2 == "10")
    let order = try FollowGroupCommand(.order([9,4]),owner:"10")
    do {
      try await order.apply(active:"10") { path,fields,uid in calls.append((path,fields,uid)); throw ServiceError("fixture rejection") }
      fatalError("reported false success")
    } catch { precondition(calls.count == 2 && calls[1].1["tagids"] == "9,4") }
    print("PASS: legacy blacklist merge/exact 64-bit IDs, untouched preferences, no partial malformed writes; reviewed group account, reserved tags, order, request fields and failure without retry")
  }
}
