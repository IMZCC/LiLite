import Foundation

@main enum CreatorPlaylistCheck {
  @MainActor static func main() async throws {
    let db = "pili.fixture.creator.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: db)!
    defer { defaults.removePersistentDomain(forName: db) }
    let owners = CreatorQueueOwners(main: "A", recommend: "R", history: "H", video: "V")
    let matched = CreatorQueueOwners(main: "A", recommend: "A", history: "A", video: "A")
    func scope(
      _ src: CreatorArchiveSource = .uploads(77), order: String = "pubdate", rev: Bool = false,
      tag: Int = 0, term: String = "", _ actors: CreatorQueueOwners? = nil
    ) -> CreatorArchiveScope {
      .init(
        source: src, title: "投稿", order: order, reverse: rev, tid: tag, special: nil, term: term,
        owners: actors ?? owners)
    }
    func list(
      _ kind: CloudLibraryKind, _ who: String = "A", term: String = "", viewed: Int = 0,
      asc: Bool = false, editable: Bool = false
    ) -> CloudPlaybackList {
      CloudPlaybackList(
        kind, uid: who, term: term, order: .mtime, viewed: viewed, ascending: asc,
        allowChanges: editable, defaults: defaults)
    }
    func current(_ q: CloudPlaybackList) -> Int64? {
      q.current.flatMap { ArchiveNumber.av($0.item.id) }
    }
    let api = BiliAPI.shared
    await api.reset()
    await AccountJar.shared.set(owners)
    let base = scope()
    let browser = CreatorPlaybackCursor(base, type: 1, desc: true, sort: 1, reportable: false)
    let a = try await browser.browsing(1)
    let b = try await browser.browsing(2)
    let count0 = await api.reads.count
    let again = try await browser.browsing(1)
    let count1 = await api.reads.count
    precondition(
      a.videos.map(\.bvid) == again.videos.map(\.bvid)
        && b.videos.first?.bvid == ArchiveNumber.bv(104) && count0 == count1)
    precondition(
      !base.mayResume(
        .init(source: base.source, text: "继续播放", uri: "bilibili://list?oid=103", owner: "R")))
    precondition(
      base.mayResume(
        .init(source: base.source, text: "继续播放", uri: "bilibili://list?oid=103", owner: "H")))
    let q = list(.creator(base, nil))
    await q.open(.init(rowID: ArchiveNumber.bv(107), page: 614))
    precondition(current(q) == 107 && q.point(q.current!)?.cid == 1070)
    let initial = await api.reads.last!
    precondition(
      initial.fields["oid"] == "107" && initial.fields["with_current"] == "true"
        && initial.owner == "A")
    for k: Int64 in [106, 105, 104, 103] {
      let moved = await q.advance(false, fullscreen: true)
      precondition(moved && current(q) == k && q.resumeFullscreen)
    }
    for k: Int64 in [104, 105, 106, 107, 108, 109, 111] {
      let moved = await q.advance(true)
      precondition(moved && current(q) == k)
    }
    precondition(q.point(q.current!)?.cid == 1110)
    let calls = await api.reads
    precondition(
      calls.contains {
        $0.fields["oid"] == "107" && $0.fields["direction"] == "true" && $0.fields["otype"] == "2"
      })
    precondition(calls.contains { $0.fields["oid"] == "109" && $0.fields["direction"] == "false" })
    await q.reverse(fullscreen: true)
    precondition(current(q) == 112 && q.showsReversed && q.resumeFullscreen)
    let start = await api.reads.last!
    precondition(start.fields["oid"] == nil && start.fields["desc"] == "false")
    let q2 = list(.creator(base, nil))
    await q2.open(.init(resume: true))
    precondition(q2.current?.item.id == q.current?.item.id && q2.showsReversed)
    let moved = await q2.advance(true)
    precondition(moved && current(q2) == 111)
    for _ in 0..<80 {
      if await api.posts.contains(where: { $0.fields["oid"] == "111" && $0.fields["desc"] == "0" })
      {
        break
      }
      try await Task.sleep(for: .milliseconds(3))
    }
    let posts = await api.posts
    precondition(
      posts.allSatisfy {
        $0.path == "/x/v1/medialist/history" && $0.owner == "H"
          && Set($0.fields.keys) == Set(["oid", "upper_mid", "desc"])
          && $0.fields["upper_mid"] == "77"
      })
    precondition(posts.contains { $0.fields["oid"] == "111" && $0.fields["desc"] == "0" })
    print(
      "UP cursor: centred resume, both directions, invalid CID skipped, full-screen carry, reverse endpoint and account-scoped local/cloud marks"
    )
    let last = list(.creator(base, nil))
    await last.open(.init(rowID: ArchiveNumber.bv(112)))
    let readsBefore = await api.reads.count
    let wrapped = await last.ended(true, .cycle)
    let readsAfter = await api.reads.count
    precondition(
      wrapped == .advanced && current(last) == 101 && readsAfter == readsBefore + 1
        && last.resumeFullscreen)
    let collection = scope(.season(77, 321), order: "pubdate", rev: false, matched)
    await AccountJar.shared.set(matched)
    let hint = try await CreatorArchiveCatalog.hint(collection)!
    precondition(hint.type == 8 && hint.resume == 107 && hint.sort == 2)
    let season = list(.creator(collection, hint))
    await season.open(.init(resume: true))
    precondition(current(season) == 107)
    let req = await api.reads.last!
    precondition(
      req.fields["oid"] == "107" && req.fields["type"] == "8" && req.fields["biz_id"] == "321"
        && req.fields["desc"] == "true" && req.fields["sort_field"] == "2")
    let fresh = list(.creator(collection, hint))
    await fresh.open(.init())
    precondition(current(fresh) == 112)
    let first = await api.reads.last!
    precondition(first.fields["desc"] == "false" && first.fields["sort_field"] == "1")
    let grouped = list(.creator(scope(.series(77, 987), rev: true, matched), nil))
    await grouped.open(.init(rowID: ArchiveNumber.bv(932), page: 2))
    precondition(current(grouped) == 932)
    let sr = await api.reads.last!
    precondition(
      sr.path == "/x/series/archives" && sr.fields["sort"] == "asc"
        && sr.fields["series_id"] == "987" && sr.owner == "A")
    let filtered = list(.creator(scope(tag: 7, term: "图书", matched), nil))
    await filtered.open(.init(rowID: ArchiveNumber.bv(929), page: 1))
    precondition(current(filtered) == 929)
    let f1 = await filtered.advance(true)
    let f2 = await filtered.advance(true)
    precondition(f1 && f2 && current(filtered) == 931)
    let fc = await api.reads.last!
    precondition(
      fc.path == "/x/space/wbi/arc/search" && fc.fields["keyword"] == "图书"
        && fc.fields["tid"] == "7" && fc.fields["pn"] == "2")
    let different = list(.creator(scope(tag: 8, term: "图书", matched), nil))
    precondition(filtered.key != different.key && fresh.key != q2.key)
    await api.reject(true)
    let retry = list(.creator(collection, hint))
    await retry.open(.init(resume: true))
    precondition(retry.current == nil && retry.issue != nil)
    await api.reject(false)
    print(
      "Season and series: provider type/remote anchor and order verified; exact keyword/category survives paging; service denial did not start another video"
    )
    let marks = CloudPlaybackList.marks(defaults)
    precondition(marks[q.key]?.id == last.current?.item.id)
    let outsider = scope(.uploads(77), order: "pubdate", rev: false, matched)
    precondition(outsider.storageKey != base.storageKey)
    let privateActors = CreatorQueueOwners(main: "A", recommend: "R", history: "", video: "V")
    precondition(
      scope(.uploads(77), privateActors).history(aid: 101, descending: true, canReport: true) == nil
    )
    await AccountJar.shared.set(owners)
    let reporter = CreatorHistoryReporter()
    await api.reset()
    await api.reject(true)
    let p = base.history(aid: 106, descending: true, canReport: true)!
    reporter.changed(p, owners: owners)
    await reporter.settled()
    let refused = await api.posts.count
    precondition(refused == 0)
    await api.reject(false)
    reporter.changed(p, owners: owners)
    await reporter.settled()
    reporter.changed(p, owners: owners)
    await reporter.settled()
    await AccountJar.shared.set(privateActors)
    reporter.changed(base.history(aid: 107, descending: true, canReport: true), owners: owners)
    await reporter.settled()
    let accepted = await api.posts.count
    precondition(accepted == 1)
    reporter.stop()
    print(
      "Receipts: rejection remains retryable, accepted update is deduplicated, an account switch and private heartbeat send nothing"
    )
    await AccountJar.shared.set(matched)
    await api.reset()
    let sharedKind = CloudLibraryKind.shared(83, matched)
    let shared = list(sharedKind, editable: true)
    await shared.open(.init(rowID: ArchiveNumber.bv(107)))
    let entry = await api.reads.last!
    precondition(
      current(shared) == 107 && entry.path == "/x/v2/medialist/resource/list" && entry.owner == "A"
        && entry.fields["type"] == "3" && entry.fields["biz_id"] == "83"
        && entry.fields["oid"] == "107" && entry.fields["with_current"] == "true"
        && entry.fields["desc"] == "true" && entry.fields["otype"] == nil)
    precondition(!shared.allowChanges && !sharedKind.canTransfer && sharedKind.folder == nil)
    for k: Int64 in [106, 105, 106, 107, 108] {
      let moved = await shared.advance(k > (current(shared) ?? 0))
      precondition(moved && current(shared) == k)
    }
    let stepEP = await shared.advance(true, fullscreen: true)
    precondition(stepEP && shared.current?.item.id == "ep:701" && shared.resumeFullscreen)
    let stepNext = await shared.advance(true)
    precondition(stepNext && current(shared) == 111)
    let mixed = await api.reads
    precondition(
      mixed.contains { $0.fields["otype"] == "24" && $0.fields["oid"] == "109" }
        && mixed.contains { $0.fields["direction"] == "true" })
    await shared.reverse()
    precondition(current(shared) == 112 && shared.showsReversed)
    await shared.remove(shared.current!)
    do {
      try await sharedKind.remove("109", uid: "A")
      preconditionFailure()
    } catch {}
    do {
      try await sharedKind.transfer("109", to: 99, copy: true, uid: "A")
      preconditionFailure()
    } catch {}
    let manual = list(sharedKind)
    await manual.open(.init(rowID: ArchiveNumber.bv(110)))
    precondition(current(manual) == 110 && manual.point(manual.current!) == nil)
    let afterManual = await manual.advance(true)
    precondition(afterManual && current(manual) == 111)
    let sharedPosts = await api.posts.count
    precondition(sharedPosts == 0)
    let missing = list(sharedKind)
    await missing.open(.init(rowID: ArchiveNumber.bv(2000)))
    precondition(missing.current == nil && missing.issue != nil)
    let foreign = list(.shared(83, owners))
    precondition(shared.key != foreign.key)
    let favKey = list(.favorites(.init(id: 83, title: "夹", media_count: 8))).key
    precondition(shared.key != favKey)
    print(
      "Shared type 3: exact BV anchor/CID, previous/next pages, episode with type 24 boundary, reverse, no fallback for absent anchor, account isolation and zero list writes"
    )
    let fav = list(
      .favorites(.init(id: 83, title: "夹", media_count: 8)), term: "搜索", editable: true)
    await fav.open(.init())
    precondition(fav.current?.item.id == "2")
    await fav.reverse(fullscreen: true)
    precondition(fav.current?.item.id == "8" && fav.resumeFullscreen)
    await fav.remove(fav.current!, fullscreen: true)
    precondition(fav.current?.item.id == "7" && fav.window.reversed && fav.resumeFullscreen)
    let deletion = await api.posts.last!
    precondition(
      deletion.path == "/x/v3/fav/resource/batch-deal" && deletion.fields["resources"] == "8"
        && deletion.owner == "A")
    let later = list(.later, term: "搜索", viewed: 2, asc: true, editable: true)
    await later.open(.init())
    precondition(later.current?.item.id == "6")
    let advanced = await later.ended(true, .order)
    precondition(advanced == .advanced && later.current?.item.id == "4" && later.resumeFullscreen)
    let v = await later.advance(true)
    precondition(v && later.current?.item.id == "2")
    let end = await later.ended(false, .order)
    precondition(end == .end)
    let cycle = await later.ended(true, .cycle)
    precondition(cycle == .advanced && later.current?.item.id == "6")
    let writes = await api.posts.count
    let readonly = list(.favorites(.init(id: 93, title: "公共", media_count: nil)))
    await readonly.open(.init())
    await readonly.remove(readonly.current!)
    let after = await api.posts.count
    precondition(after == writes)
    let lastRead = await api.reads.last(where: { $0.path == "later" })!
    precondition(
      lastRead.fields["query"] == "搜索" && lastRead.fields["viewed"] == "2"
        && lastRead.fields["ascending"] == "true")
    print(
      "Favorites and watch-later: exact search/view filters, unavailable item skipped, reverse across pages, deletion receipt selects a valid neighbor, cycle and public read-only verified"
    )
  }
}
