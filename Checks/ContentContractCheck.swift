import Foundation

@main enum ContentContractCheck {
  static func main() async throws {
    precondition(SharedLink.parse("https://www.bilibili.com/h5/note-app/view?cvid=318")==(.article(318)))
    precondition(SharedLink.parse("https://m.bilibili.com/mobile/note?cvid=319")==(.article(319)))
    precondition(SharedLink.parse("https://www.bilibili.com/read/mobile-readlist/rl25")==(.articleList(25)))
    precondition(SharedLink.parse("https://evil.example/h5/note-app/view?cvid=318")==nil && SharedLink.parse("https://www.bilibili.com/h5/note-app/view?cvid=318&cvid=319")==nil)

    precondition(
      BulletTrackFrame.timeLink("空降 01：03", duration: 65) == 63
        && BulletTrackFrame.timeLink("2:00", duration: 120) == nil)
    let extent = CGSize(width: 200, height: 100)
    let scrollingRect = BulletTrackFrame.rect(
      mode: 1, lane: 2, width: 40, point: 10, step: 16, elapsed: 5, duration: 10, size: extent)
    precondition(scrollingRect == CGRect(x: 80, y: 32, width: 40, height: 13))
    precondition(
      BulletTrackFrame.rect(
        mode: 6, lane: 0, width: 40, point: 10, step: 16, elapsed: 0, duration: 10, size: extent)?
        .minX == -40)
    precondition(
      BulletTrackFrame.rect(
        mode: 4, lane: 1, width: 40, point: 10, step: 16, elapsed: 8, duration: 10, size: extent)?
        .minY == 16)
    precondition(
      BulletTrackFrame.rect(
        mode: 5, lane: 0, width: 40, point: 10, step: 16, elapsed: 11, duration: 10, size: extent)
        == nil)
    let payload = #"[0.25,0.5,"0.2-1",6,"demo",15,0,"1440","540",2000,1000,1,"",0]"#
    let tail = RelayRange("bytes=-5", length: 14)
    precondition(tail?.first == 9 && tail?.last == 13)
    precondition(
      RelayRange("bytes=0-0", length: 14)?.last == 0
        && RelayRange("bytes=13-", length: 14)?.first == 13)
    precondition(
      RelayRange("bytes=14-", length: 14) == nil && RelayRange("bytes=2-1", length: 14) == nil
        && RelayRange("bytes=0-1,5-7", length: 14) == nil)
    let xml = "<i><d p=\"4.5,7,30,16711680,0,0,0,1\">\(payload)</d></i>"
    let xmlItems = try DanmakuXML.parse(Data(xml.utf8))
    func integer(_ n: Int) -> [UInt8] {
      var v = n
      var out: [UInt8] = []
      repeat {
        let b = UInt8(v & 127)
        v >>= 7
        out.append(v == 0 ? b : b | 128)
      } while v > 0
      return out
    }
    let bytes = Array(payload.utf8)
    var fields = [UInt8]([16]) + integer(4500) + [24, 7, 32, 30, 40]
    fields += integer(0xff0000) + [8, 1, 50, 1, 48, 58] + integer(bytes.count) + bytes
    let packet = Data([10] + integer(fields.count) + fields)
    let colored = fields + integer(24 << 3) + integer(60001)
    let vip = try DMProto.parse(Data([10] + integer(colored.count) + colored))
    precondition(vip.first?.isVIPGradient == true)
    let protobuf = try DMProto.parse(packet)
    precondition(xmlItems == protobuf && xmlItems.count == 1)
    var style = DanmakuStyle()
    style.merge = true
    style.expressions = "广告[0-9]+"
    style.senders = "abcd"
    let moving = Bullet(time: 1, mode: 1, rgb: 0xffffff, text: "一起看", sender: "other", weight: 8)
    var own = moving
    own.sender = "myself"
    let hidden = Bullet(time: 2, mode: 1, rgb: 0xffffff, text: "广告52", weight: 7)
    let next = Bullet(time: 361, mode: 1, rgb: 0xffffff, text: moving.text, weight: 8)
    let list = style.visible([moving, moving, own, hidden, next], keywords: "test", own: "myself")
    precondition(list.map(\.repeats) == [2, 1, 1])
    let uidHash = try CloudBulletRule.input("1", type: 2)
    let tapHash = try CloudBulletRule.input("83DCEFB7", type: 2, senderHash: true)
    precondition(uidHash == "83dcefb7" && tapHash == uidHash)
    let matcher = CloudBulletMatcher([.init(id: 1, type: 0, filter: "Case"),
      .init(id: 2, type: 1, filter: "/^广告[A-Z]+$/"), .init(id: 3, type: 2, filter: uidHash)])
    precondition(matcher.hides(text: "Case", sender: nil) && !matcher.hides(text: "case", sender: nil))
    precondition(matcher.hides(text: "广告abc", sender: nil) && matcher.hides(text: "", sender: tapHash))
    precondition((try? CloudBulletRule.input("83dcefb7", type: 2)) == nil)
    style.minimumWeight = 9
    precondition(style.visible([moving], keywords: "", own: nil).isEmpty)
    precondition(DanmakuStyle.senderHash("1") == "83dcefb7")
    var layoutStyle = DanmakuStyle()
    layoutStyle.convertFixed = true
    layoutStyle.duration = 50
    try layoutStyle.validate()
    precondition(BulletLanes.count(height: 100, area: 0.5, step: 20) == 2)
    precondition(BulletLanes.count(height: 100, area: 1, step: 20) == 4)
    var lanes = BulletLanes(count: 2, width: 200)
    let lower = lanes.place(mode: 4, at: 0, width: 50, own: false, style: layoutStyle, seed: 0)
    let upper = lanes.place(mode: 5, at: 0, width: 70, own: false, style: layoutStyle, seed: 0)
    precondition(lower?.lane == 1 && lower?.mode == 4 && upper?.lane == 0 && upper?.mode == 5)
    let overflow = lanes.place(mode: 4, at: 1, width: 45, own: false, style: layoutStyle, seed: 0)
    precondition(overflow?.mode == 1 && overflow?.duration == 50)
    layoutStyle.hideScroll = true
    precondition(lanes.place(mode: 5, at: 1, width: 250, own: false, style: layoutStyle, seed: 0) == nil)
    layoutStyle.hideScroll = false; layoutStyle.fixedVelocity = true
    var steady = BulletLanes(count: 1, width: 200)
    precondition(steady.place(mode: 1, at: 0, width: 100, own: false, style: layoutStyle, seed: 0)?.duration == 75)
    precondition(steady.place(mode: 1, at: 24.9, width: 20, own: false, style: layoutStyle, seed: 0) == nil)
    precondition(steady.place(mode: 1, at: 25, width: 20, own: false, style: layoutStyle, seed: 0) != nil)
    precondition(steady.place(mode: 1, at: 25, width: 20, own: true, style: layoutStyle, seed: 0)?.lane == 0)
    let largeSegment = (0..<50_000).map { i in
      Bullet(time: Double(i) / 10, mode: 1, rgb: 0xffffff, text: "repeated \(i % 25)", entryID: Int64(i))
    }
    let prepared = try await Task.detached {
      var measures = 0, mainThread = false
      let start = Date()
      let plan = try BulletLayoutPlan.prepare(largeSegment, style: DanmakuStyle(), keywords: "", own: nil,
        cloud: .init([]), size: CGSize(width: 400, height: 240), area: 0.5, point: 15) { text, _ in
          measures += 1; mainThread = mainThread || Thread.isMainThread
          return Double(text.utf8.count * 8)
        }
      return (plan, measures, mainThread, Date().timeIntervalSince(start))
    }.value
    precondition(!prepared.0.rows.isEmpty && prepared.1 == 26 && !prepared.2)
    let abandoned = Task.detached {
      var measures = 0
      let unique = largeSegment.enumerated().map { i, item in
        Bullet(time: item.time, mode: 1, rgb: item.rgb, text: String(i), entryID: item.entryID)
      }
      return try BulletLayoutPlan.prepare(unique, style: DanmakuStyle(), keywords: "", own: nil,
        cloud: .init([]), size: CGSize(width: 400, height: 240), area: 0.5, point: 15) { _, _ in
          measures += 1
          if measures == 32 { withUnsafeCurrentTask { $0?.cancel() } }
          precondition(measures < 128)
          return 80
        }
    }
    do { _ = try await abandoned.value; preconditionFailure("cancelled layout was published") }
    catch is CancellationError {}
    print("Danmaku preparation: 50,000 comments, \(prepared.1) unique measurements, \(prepared.0.rows.count) placed rows, background worker and mid-layout cancellation passed (\(Int(prepared.3 * 1000)) ms)")
    // Seek in either direction on a segment with overlapping lifetimes. Only the visible
    // window is admitted (including the start boundary and excluding the end), even in dense mode.
    let starts = [0.0, 1, 2, 3, 4, 5, 6], spans = [8.0, 1, 1, 3, 1, 1, 1]
    let index = try BulletWindowIndex(count: starts.count) { starts[$0] + spans[$0] }
    func window(_ t: Double, _ cap: Int) -> [Int] {
      index.window(now: t, ahead: 1, limit: cap,
        start: { starts[$0] }, end: { starts[$0] + spans[$0] })
    }
    precondition(window(5, 8) == [0, 3, 5, 6] && window(5, 2) == [3, 5])
    precondition(window(1, 8) == [0, 1, 2] && window(8, 8).isEmpty)
    let burst = Array(repeating: 3.0, count: 50_000)
    let dense = try BulletWindowIndex(count: burst.count) { _ in 9 }
    precondition(dense.window(now: 3, ahead: 1, limit: 96,
      start: { burst[$0] }, end: { _ in 9 }) == Array(49_904..<50_000))
    // A long-lived effect survives 49,999 short neighbours. Seeking back and forth must
    // still find it without inspecting each expired item on the main thread.
    let sparse = try BulletWindowIndex(count: burst.count) { $0 == 0 ? 300 : 5 }
    var readEnds = 0
    for t in [200.0, 10, 299, 5] {
      let active = sparse.window(now: t, ahead: 0, limit: 24, start: { burst[$0] },
        end: { readEnds += 1; return $0 == 0 ? 300 : 5 })
      precondition(active == [0])
    }
    precondition(readEnds <= 4 * 32)
    print("Sparse 50,000-row danmaku seek: \(readEnds) end checks across four jumps")
    var muted = moving; muted.sender = "abcd"
    style.minimumWeight = 0
    precondition(style.visible([muted, moving, own], keywords: "", own: "myself").map(\.item) == [own])
    let bullet = xmlItems[0]
    let s = bullet.special!
    precondition(s.frame(0.5).x == 0.25 && s.frame(2).x == 0.5 && s.frame(5).x == 0.75)
    precondition(s.frame(3).y == 0.5 && abs(s.frame(3).opacity - 0.6) < 1e-8)
    for data in [
      Data(packet.dropLast()), Data([10, 255, 255, 255, 255, 255, 255, 255, 255, 255, 128]),
      Data([10, 2, 58, 127]),
    ] { precondition((try? DMProto.parse(data)) == nil) }
    precondition(SpecialBullet(#"[0,0,"1-1","Infinity","text"]"#) == nil)
    precondition(
      SharedLink.parse("https://www.bilibili.com/video/BV1xx411c7mD/?p=3&t=10")
        == .positioned(.video("BV1xx411c7mD", 3), 10))
    precondition(
      SharedLink.parse("https://www.bilibili.com/read/readlist/rl152") == .articleList(152))
    precondition(SharedLink.parse("https://www.bilibili.com/opus/1234") == .opus("1234"))
    precondition(
      SharedLink.parse(
        "bilibili://comment/detail/17/812345678901234567/238686570016/?anchor=238686628816")
        == .replies(812_345_678_901_234_567, 17, 238_686_570_016, 238_686_628_816))
    precondition(
      SharedLink.parse("bilibili://video/1245?comment_root_id=80&comment_secondary_id=91")
        == .commentOn(.archive(1245, nil), 80, 91))
    precondition(SharedLink.parse("bilibili://following/detail/3333") == .dynamic("3333"))
    precondition(
      SharedLink.parse(
        "https://www.bilibili.com/video/av1245?comment_on=1&comment_root_id=80&comment_secondary_id=91"
      ) == SharedLink.commentOn(.archive(1245, nil), 80, 91))
    precondition(SharedLink.parse("https://m.bilibili.com/topic-detail?topic_id=12") == .topic(12))
    precondition(SharedLink.parse("https://www.bilibili.com/v/topic/detail?topic_id=12") == .topic(12))
    precondition(SharedLink.parse("bilibili://m.bilibili.com/topic-detail?topic_id=12") == .topic(12))
    precondition(SharedLink.parse("https://www.bilibili.com/h5/topic-active/topic-report?topic_id=12") == nil)
    precondition(SharedLink.parse("bilibili://video/42?cid=81&dm_progress=13500") == .positioned(.archivePart(.archive(42, nil), 81), 10.5))
    precondition(SharedLink.parse("bilibili://following/detail/cv91") == .article(91))
    precondition(SharedLink.parse("bilibili://search?keyword=%E9%9F%B3%E4%B9%90") == .search("音乐"))
    precondition(SharedLink.parse("bilibili://main/favorite?tab=topic") == .favorites("topic"))
    precondition(SharedLink.parse("bilibili://login?code=one-use") == nil)
    precondition(SharedLink.parse("piliplus://episode/123") == .episode(123))
    precondition(SharedLink.parse("BV1xx411c7mD") == .video("BV1xx411c7mD", nil))
    precondition(
      SharedLink.parse("https://www.bilibili.com/video/av8?p=1&dm_progress=1200&t=9")
        == .positioned(.archive(8, 1), 0))
    precondition(
      SharedLink.parse("https://www.bilibili.com/bangumi/play/ep7?start_progress=7500&t=2")
        == .positioned(.episode(7), 7.5))
    precondition(SharedLink.parse("https://www.bilibili.com/video/av8?t=nan") == .archive(8, nil))
    precondition(SharedLink.parse("https://space.bilibili.com/42/upload/video") == .creator(42))
    precondition(
      SharedLink.parse("https://www.bilibili.com@unrelated.invalid/video/BV1xx411c7mD") == nil)
    precondition(SharedLink.parse("https://unrelated.invalid/video/BV1xx411c7mD") == nil)
    precondition(SharedLink.parse("https://www.bilibili.com/video/BV1xx411c7mD?p=4&cid=150&dm_progress=11200&comment_root_id=751&comment_secondary_id=901") == .commentOn(.positioned(.archivePart(.video("BV1xx411c7mD",4),150),8.2),751,901))
    precondition(SharedLink.parse("https://www.bilibili.com/bangumi/play/ep155?comment_root_id=9&t=20") == .commentOn(.positioned(.episode(155),20),9,nil))
    precondition(SharedLink.parse("https://www.bilibili.com/cheese/play/ep155?comment_root_id=9&comment_secondary_id=13") == .commentOn(.course(155,true),9,13))
    precondition(SharedLink.parse("bilibili://following/detail/95?type=2&comment_root_id=19") == .commentOn(.album(95),19,nil))
    precondition(SharedLink.parse("bilibili://comment/msg_fold/11/92/19/50/?anchor=50&enterUri=bilibili%3A%2F%2Ffollowing%2Fdetail%2F95") == .commentOn(.dynamic("95"),19,50))
    precondition(SharedLink.parse("bilibili://comment/msg_fold/11/92/19/?enterUri=https://other.test/95") == .replies(92,11,19,nil))
    precondition(SharedLink.parse("https://www.bilibili.com/h5/comment/sub?oid=55&pageType=12&root=93&comment_secondary_id=94") == .commentOn(.dynamic("55"),93,94))
    precondition(SharedLink.parse("https://www.bilibili.com/h5/vote?vote_id=500&dynamic_id=72") == .contextVote(500,72))
    precondition(SharedLink.parse("https://www.bilibili.com/playlist/pl58?bvid=BV1xx411c7mD") == .sharedPlaylist(58,"BV1xx411c7mD"))
    precondition(SharedLink.parse("https://space.bilibili.com/h5/follow?mid=41&type=followed") == .cofollow(41))
    precondition(SharedLink.parse("bilibili://space/realname/91") == .disclosure(91))
    precondition(SharedLink.parse("bilibili://browser/?url=https%3A%2F%2Fexample.org%2F") == .browser(URL(string:"https://example.org/")!))
    precondition(SharedLink.parse("bilibili://browser/?url=javascript%3Afoo") == nil)
    precondition(SharedLink.parse("bilibili://browser/?url=https://ok.test&url=https://bad.test") == nil)
    precondition(SharedLink.parse("https://t.bilibili.com/12?type=2") == .album(12))
    precondition(SharedLink.parse("bilibili://video/12?comment_root_id=1&comment_root_id=2") == .archive(12,nil))
    precondition(SharedLink.parse("//music.bilibili.com/h5/music-detail?music_id=MA804343") == .music("MA804343"))
    precondition(SharedLink.parse("music.bilibili.com/pc/music-detail?music_id=MA638xy") == .music("MA638xy"))
    precondition(SharedLink.parse("https://music.bilibili.com/h5/music-detail?music_id=MA1%2F2") == nil)
    precondition(SharedLink.parse("https://m.bilibili.com/v/playlist/pl73/BV1xx411c7mD") == .sharedPlaylist(73,"BV1xx411c7mD"))
    precondition(SharedLink.parse("https://www.bilibili.com/mobile/video/av42") == .archive(42,nil))
    print(
      "XML/protobuf equivalence, animation timing, truncated packets and content routing passed")
  }
}
