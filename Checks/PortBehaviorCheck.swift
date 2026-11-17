import Foundation

@main enum PortBehaviorCheck {
  static func main() async throws {
    let yt = URL(string:"https://youtu.be/abC_DEfg-12?t=40")!
    let origin = SponsorSource(archive:"BV1xx411c7mD",cid:31,duration:180.6,link:yt)!
    precondition(origin.lookup == ["videoID":"BV1xx411c7mD","cid":"31"] && origin.fields(identity:"local")["biliDuration"] as? Int == 181)
    precondition(SponsorSource.youtubeID(URL(string:"https://www.youtube.com/watch?v=abC_DEfg-12&v=aaaaaaaaaaa")!) == nil)
    precondition(SponsorSource.youtubeID(URL(string:"https://youtube.com.invalid/embed/abC_DEfg-12")!) == nil)
    precondition(SponsorSource(archive:"av99",cid:31,duration:0.2,link:yt) == nil)
    let privateFlags = try JSONDecoder().decode(SpacePrivacyValues.self, from: Data(#"{"fav_video":1,"disable_following":0,"news":{},"comic":null,"dress_up":2}"#.utf8))
    precondition(privateFlags.values == ["fav_video":1, "disable_following":0])
    let combinedPrivacy = try SpacePrivacyValues.merge(baseline: privateFlags.values, draft: ["fav_video":0,"disable_following":0],
      latest:["fav_video":1,"disable_following":1])
    precondition(combinedPrivacy == ["fav_video":0,"disable_following":1])
    let conflict = try? SpacePrivacyValues.merge(baseline:["fav_video":0],draft:["fav_video":1],latest:[:])
    precondition(conflict == nil)
    let viewport = CGSize(width: 300, height: 180), source = CGSize(width: 100, height: 100)
    precondition(PictureFit.width.geometry(view: viewport, source: source).size == CGSize(width: 300, height: 300))
    precondition(PictureFit.height.geometry(view: viewport, source: source).size == CGSize(width: 180, height: 180))
    precondition(PictureFit.down.geometry(view: viewport, source: source).size == source)
    precondition(PictureFit.fourThree.geometry(view: viewport, source: source).size == CGSize(width: 240, height: 180))
    precondition(PictureFit.stretch.geometry(view: viewport, source: CGSize(width: 20, height: 40), firstChoice: true).gravity == "fit")
    let grant = try JSONDecoder().decode(ArchiveStreamGrant.self, from: Data(#"{"is_preview":1,"support_formats":[{"quality":80,"need_login":true},{"quality":112,"need_vip":1},{"quality":32,"need_login":false}]}"#.utf8))
    precondition(grant.preview && !grant.permitsCache && !grant.permits(80, guest: true) && grant.permits(32, guest: true))
    precondition(ArchiveStreamGrant.automaticHD([32], guest: true, enabled: true, explicit: false) == nil)
    precondition(ArchiveStreamGrant.automaticHD([32,80], guest: true, enabled: true, explicit: false) == 80)
    precondition(ArchiveStreamGrant.automaticHD([32,80], guest: true, enabled: true, explicit: true) == nil)
    let rawProxy = APIProxy(enabled: true, host: " [::1] ", port: "07890")
    let proxy = try rawProxy.validated()
    precondition(proxy.endpoint == "[::1]:7890")
    for (host, port) in [
      ("https://user@host", "443"), ("11.22.33.999", "80"), ("host", "99999"), ("", "443"),
    ] {
      do {
        _ = try APIProxy(enabled: true, host: host, port: port).validated()
        preconditionFailure("invalid proxy accepted")
      } catch {}
    }
    let signedA = URL(
      string: "https://upos-sz-mirrorali.bilivideo.com/upgcxcode/00/11/v.m4s?k=a%2Fb%2Bc&k=x")!
    let signedHW = URL(
      string: "https://upos-sz-mirrorhw.bilivideo.com/upgcxcode/00/11/v.m4s?different=1")!
    let bound = URL(string: "https://upos-hz-mirrorakam.akamaized.net/upgcxcode/a?hdnts=abc")!
    let urls = [bound, signedA, signedHW, signedA]
    precondition(VODLine.allCases.count == 21)
    precondition(
      VODLine.hw.routes(urls, audio: false, independent: true) == [signedHW, bound, signedA])
    precondition(
      VODLine.hw.routes(urls, audio: true, independent: true) == [signedA, bound, signedHW])
    precondition(VODLine.baseUrl.routes(urls, audio: true, independent: true).first == bound)
    precondition(
      VODLine.cos.candidate([signedA])?.absoluteString
        == signedA.absoluteString.replacingOccurrences(of: "mirrorali.", with: "mirrorcos."))
    precondition(
      VODLine.akamai.candidate([signedA]) == nil && VODLine.tf_hw.candidate([signedA]) == nil)
    precondition(VODLine.ali.candidate([bound]) == nil)
    let restricted = URL(string: signedA.absoluteString + "&os=mcdn")!
    precondition(VODLine.cos.candidate([restricted]) == nil)
    precondition(
      VODLine.originals([URL(string: "https://u:p@h.example/video")!, bound, bound]) == [bound])
    let liveJSON =
      #"{"live_status":1,"playurl_info":{"playurl":{"stream":[{"protocol_name":"http_stream","format":[{"format_name":"flv","codec":[{"codec_name":"avc","base_url":"/a.flv","current_qn":400,"accept_qn":[400,80],"url_info":[{"host":"https://a.example","extra":"?k=1"},{"host":"https://b.example","extra":"?k=2"},{"host":"https://a.example","extra":"?k=1"}]},{"codec_name":"avc","base_url":"/low.flv","current_qn":80,"url_info":[{"host":"https://c.example"}]}]}]},{"protocol_name":"http_hls","format":[{"format_name":"fmp4","codec":[{"codec_name":"hevc","base_url":"/p.m3u8","current_qn":400,"url_info":[{"host":"https://d.example"}]}]}]}]}}}"#
    let lr = try JSONDecoder().decode(LiveSource.self, from: Data(liveJSON.utf8)).variants
    precondition(
      lr.count == 2 && lr[0].id.remux && !lr[1].id.remux && LiveFormat(lr[0].id.triple) == lr[0].id)
    precondition(
      lr[0].endpoints.map(\.quality) == [400, 400, 80]
        && lr[0].sources.map(\.query) == ["k=1", "k=2", nil])
    precondition(
      LiveLocalAsset(target: "/token/part00000003.m4s?x=1", secret: "token")?.name
        == "part00000003.m4s")
    for path in [
      "/wrong/init.mp4", "/token/../file", "/token/%2e%2e", "/token/part00000000.m4s.tmp",
      "//token/index.m3u8",
    ] { precondition(LiveLocalAsset(target: path[...], secret: "token") == nil) }
    let customOrigin = LiveCDNOrigin("edge.example:8443/relay/")!
    let routePlan = lr[0].routes(first: 1, custom: customOrigin)
    precondition(
      routePlan[0].url.absoluteString == "https://edge.example:8443/relay/a.flv?k=2"
        && routePlan[0].line == 1 && routePlan[1].url.host == "b.example")
    precondition(
      customOrigin.stream("/a.flv?k=a%2Fb%2Bc")?.absoluteString.hasSuffix("k=a%2Fb%2Bc") == true)
    for s in [
      "http://edge.example", "https://user:pass@edge.example", "https://edge.example/?cookie=x",
      "https://edge.example/%2e%2e/path",
    ] { precondition(LiveCDNOrigin(s) == nil) }
    precondition(customOrigin.stream("//elsewhere.example/a") == nil)
    struct ChatRow: Identifiable {
      let id: Int, text: String
      init(_ id: Int, _ text: String = "") {
        self.id = id
        self.text = text
      }
    }
    var chatWindow = ChatWindow<ChatRow>()
    chatWindow.receive([ChatRow(4), ChatRow(3)], next: "3", older: false)
    chatWindow.receive([ChatRow(3, "updated"), ChatRow(2), ChatRow(1)], next: "1", older: true)
    precondition(chatWindow.rows.map(\.id) == [1, 2, 3, 4] && chatWindow.rows[2].text == "updated")
    chatWindow.receive([ChatRow(5), ChatRow(4)], next: "4", older: false)
    precondition(chatWindow.rows.map(\.id) == [1, 2, 3, 4, 5] && chatWindow.next == "1")
    chatWindow.receive([ChatRow(30), ChatRow(29)], next: "29", older: false)
    precondition(chatWindow.rows.map(\.id) == [29, 30] && chatWindow.next == "29")
    let e = RichNode.Emote(
      name: "[笑]", url: URL(string: "https://i0.hdslb.com/face.png")!, size: 2, jump: nil,
      jumpTitle: nil, animation: nil)
    let chat = IMHistoryPolicy.tokenize(
      "甲[笑] https://www.bilibili.com/video/BV17x411w7KC 未知[微笑]", emotes: ["[笑]": e])
    precondition(
      chat.map(\.text).joined() == "甲[笑] https://www.bilibili.com/video/BV17x411w7KC 未知[微笑]"
        && chat.filter { $0.emote != nil }.count == 1)
    precondition(chat.contains { $0.target == .route(.video("BV17x411w7KC", nil)) })
    precondition(
      IMHistoryPolicy.recall(#"{"msg_key":"18446744073709551615"}"#) == IMHistoryPolicy.key("-1"))
    precondition(
      IMHistoryPolicy.older(flag: true, minimum: 18, sequences: [21, 20, 18], before: 20) == "18"
        && IMHistoryPolicy.older(flag: true, minimum: 20, sequences: [20], before: 20) == nil)
    let notify = IMCardBody(
      type: 10,
      data: [
        "title": "通知", "text": "正文", "modules": [["title": "分类", "detail": "内容"]],
        "jump_uri_2": "https://www.bilibili.com/video/BV17x411w7KC", "jump_text_2": "原稿",
      ], fallback: "消息")
    precondition(
      notify.rows.count == 3 && notify.rows.last?.target == .route(.video("BV17x411w7KC", nil)))
    let tips = IMCardBody(
      type: 18, data: ["content": #"[{"text":"甲"},{"text":"乙"}]"#], fallback: "消息")
    precondition(tips.rows.first?.title == "甲\n乙")
    func audio(
      _ mode: AudioSequence, _ automatic: Bool, _ row: Int, _ count: Int, _ part: Int?,
      _ parts: Int, _ direction: Int = 1
    ) -> AudioSequence.Action {
      mode.action(
        automatic: automatic, direction: direction, row: row, count: count, part: part, parts: parts
      )
    }
    precondition(
      audio(.list, true, 0, 3, 0, 2) == .part(1) && audio(.list, true, 0, 3, 1, 2) == .row(1))
    precondition(
      audio(.one, true, 0, 3, 0, 2) == .current && audio(.pause, true, 0, 3, 0, 2) == .stop)
    precondition(
      audio(.all, true, 2, 3, 1, 2) == .row(0) && audio(.list, true, 2, 3, nil, 0) == .stop)
    precondition(
      audio(.all, false, 0, 3, nil, 0, -1) == .unchanged
        && audio(.list, false, 0, 3, 0, 2) == .row(1))
    func schedule(_ json: String) throws -> [SeasonSchedule.Day] {
      try JSONDecoder().decode([SeasonSchedule.Day].self, from: Data(json.utf8))
    }
    let animeDays = try schedule(
      #"[{"date":"11-12","date_ts":12,"is_today":1,"episodes":[{"season_id":1,"episode_id":2,"title":"A","cover":"a"}]}]"#
    )
    let chinaDays = try schedule(
      #"[{"date":"11-11","date_ts":11},{"date":"11-12","date_ts":12,"episodes":[{"season_id":1,"episode_id":2,"title":"A","cover":"b"},{"season_id":3,"episode_id":4,"title":"B","cover":"c"}]}]"#
    )
    let combined = SeasonSchedule.merge([animeDays, chinaDays])
    precondition(
      combined.map(\.id) == [11, 12] && combined.last?.is_today == 1
        && combined.last?.episodes?.compactMap(\.episode_id) == [2, 4])
    let cover = URL(string: "https://i0.hdslb.com/bfs/archive/cover.jpg")!
    func cacheable(_ url: URL, _ control: String?, _ cookie: String? = nil) -> Bool {
      ArtworkCacheRules.admits(
        url: url, status: 200, mime: "image/jpeg", cookie: cookie, control: control)
    }
    precondition(
      cacheable(cover, "public, max-age=300") && !cacheable(cover, "max-age=5, Private")
        && !cacheable(cover, "no-store"))
    precondition(
      !cacheable(cover, nil, "x=1")
        && !cacheable(URL(string: cover.absoluteString + "?token=temporary")!, "public"))
    precondition(!cacheable(URL(string: "https://hdslb.com.example.org/p.jpg")!, "public"))
    let retry = ConnectionRetry(count: 2, delayMillis: 500)
    var waited = [Int]()
    let value: Int = try await retry.perform(readOnly: true, wait: { waited.append($0) }) { index in
      if index < 2 { throw URLError(.timedOut) }
      return index
    }
    precondition(value == 2 && waited == [500, 1000])
    for (safe, error) in [
      (false, URLError(.timedOut)), (true, URLError(.serverCertificateUntrusted)),
      (true, URLError(.cancelled)),
    ] {
      var calls = 0
      do {
        let _: Int = try await retry.perform(readOnly: safe, wait: { _ in preconditionFailure() }) {
          _ in
          calls += 1
          throw error
        }
        preconditionFailure()
      } catch let caught as URLError { precondition(calls == 1 && caught.code == error.code) }
    }
    do {
      var calls = 0
      defer { precondition(calls == 1) }
      let _: Int = try await retry.perform(readOnly: true, wait: { _ in throw CancellationError() })
      { _ in
        calls += 1
        throw URLError(.cannotFindHost)
      }
      preconditionFailure()
    } catch is CancellationError {}

    let syntheticLanguages = ["ai-zh", "ai-en"]
    func preferred(_ mode: SubtitlePreference, _ volume: Float) -> String? {
      mode.select(syntheticLanguages, language: { $0 }, isAI: { _ in false }, volume: volume)
    }
    precondition(preferred(.off, 0) == nil && preferred(.on, 1) == "ai-zh")
    precondition(
      preferred(.withoutAI, 0) == nil && preferred(.auto, 1) == nil
        && preferred(.auto, 0) == "ai-zh")
    precondition(
      SubtitlePreference.auto.select(["zh-Hans"], language: { $0 }, isAI: { _ in false }, volume: 1)
        == "zh-Hans")
    let name = "native.checks." + UUID().uuidString
    let defaults = UserDefaults(suiteName: name)!
    defer { defaults.removePersistentDomain(forName: name) }
    precondition(
      ArchiveNumber.bv(170001) == "BV17x411w7KC" && ArchiveNumber.av("BV17x411w7KC") == 170001)
    for n: Int64 in [1, 66_936_645, (1 << 51) - 1] {
      precondition(ArchiveNumber.bv(n).flatMap(ArchiveNumber.av) == n)
    }
    precondition(ArchiveNumber.bv(0) == nil && ArchiveNumber.av("BV1000000000") == nil)
    try EpisodeCachePolicy.allow(
      series: ["rights": ["allow_download": 1]], episode: [:], vip: false)
    precondition(
      (try? EpisodeCachePolicy.allow(
        series: ["rights": ["allow_download": 1]], episode: ["rights": ["allow_download": 0]],
        vip: true)) == nil)
    precondition(
      (try? EpisodeCachePolicy.allow(
        series: ["rights": ["allow_download": 1, "only_vip_download": 1]], episode: [:], vip: false))
        == nil)
    precondition(
      (try? EpisodeCachePolicy.allow(series: [:], episode: ["playable": true], vip: false)) == nil)
    precondition(
      (try? EpisodeCachePolicy.clearMedia(["dash": ["video": [["drm_info": ["key": "fixture"]]]]]))
        == nil)
    var newer = OfflineVideo(bvid: "BV1", cid: 2, title: "Title", part: "Two")
    newer.pageOrder = 2
    var older = OfflineVideo(bvid: "BV1", cid: 1, title: "Title", part: "One")
    older.pageOrder = 1
    older.generation = UUID()
    var replacement = older
    replacement.generation = UUID()
    let grouped = OfflineGroup.groups([newer, older])
    precondition(grouped.count == 1 && grouped[0].parts.map(\.cid) == [1, 2])
    precondition(older.id == replacement.id && older.token != replacement.token)
    let languages = try JSONDecoder().decode(
      SpokenCatalog.self,
      from: Data(
        #"{"support":true,"items":[{"lang":"en","title":"English","production_type":1},{"lang":"zh-CN","title":"普通话","production_type":2},{"lang":"zh-HK","title":"粤语","production_type":1},{"lang":"en","title":"repeat"}]}"#
          .utf8))
    precondition(
      languages.ordered.map(\.id) == ["zh-HK", "zh-CN", "en"]
        && languages.ordered[1].label == "普通话（AI）")
    let archive = try JSONDecoder().decode(
      VideoEngagement.self, from: Data(#"{"like":true,"coin":1,"favorite":false}"#.utf8))
    var episode = try JSONDecoder().decode(
      VideoEngagement.self, from: Data(#"{"like":0,"coin_number":2,"favorite":1}"#.utf8))
    precondition(archive.liked && !archive.starred && archive.coins == 1 && !archive.complete)
    precondition(episode.starred && !episode.liked && episode.coins == 2)
    episode.addTriple(archive)
    precondition(episode.complete && episode.coins == 2)
    let ep = EngagementItem(bvid: "BV1", aid: 71, episode: 99, copyright: 1)
    let repost = EngagementItem(bvid: "BV2", aid: 72, episode: nil, copyright: 2)
    precondition(
      ep.rid == 99 && ep.type == 24 && repost.rid == 72 && repost.type == 2 && repost.maxCoins == 1)
    do {
      var window = MediaPageWindow<String>(identify: { $0 }, playable: { $0 != "unavailable" })
      window.put(1, ["a", "unavailable"], hasNext: true)
      guard case .found(let a) = window.step(from: nil, forward: true),
        case .fetch(2) = window.step(from: a, forward: true)
      else { preconditionFailure("did not cross the page boundary") }
      window.put(2, ["a", "b"], hasNext: true)
      window.put(3, ["c"], hasNext: false)
      guard case .found(let b) = window.step(from: a, forward: true), b.item == "b" else {
        preconditionFailure("repeated boundary entry")
      }
      window.reversed = true
      guard case .found(let left) = window.step(from: b, forward: true), left.item == "a",
        case .found(let c) = window.step(from: b, forward: false), c.item == "c",
        case .finished = window.step(from: c, forward: false)
      else { preconditionFailure("reversal changed page identity") }
    }
    do {
      let parts = [
        Video.Part(cid: 51, page: 1, part: "first"), Video.Part(cid: 52, page: 2, part: "second"),
      ]
      let remote = ServiceWatchPoint(last_play_cid: 52, last_play_time: 15500)
      func choose(
        _ page: Int? = nil, _ t: Double? = nil, _ pref: Bool = true,
        _ server: ServiceWatchPoint? = nil
      ) -> ArchiveStart? {
        ArchiveStart.select(
          parts, fallback: 51, page: page, from: t, continuePart: pref, local: 52, remote: server,
          saveTime: true)
      }
      precondition(
        choose(nil, nil, true, remote)?.cid == 52 && choose(nil, nil, true, remote)?.seconds == 15.5
      )
      precondition(
        choose(1, 0, true, remote)?.cid == 51 && choose(1, 0, true, remote)?.seconds == 0)
      precondition(
        choose(nil, 5, true, remote)?.cid == 51 && choose(nil, nil, false, remote)?.cid == 51)
      precondition(
        choose(nil, nil, true, .init(last_play_cid: 99, last_play_time: 60000))?.cid == 52
          && choose(nil, nil, true, .init(last_play_cid: 99, last_play_time: 60000))?.seconds == nil
      )
    }
    do {
      let ids = [5, 2, 7]
      precondition(
        manualNeighbor(5, in: ids, forward: false, wrap: false) == nil
          && manualNeighbor(5, in: ids, forward: false, wrap: true) == 7
          && manualNeighbor(7, in: ids, forward: false, wrap: false) == 2)
      precondition(
        VideoRepeat.order.after(5, in: ids) == 2 && VideoRepeat.order.after(7, in: ids) == nil)
      precondition(
        VideoRepeat.cycle.after(7, in: ids) == 5
          && VideoRepeat.cycle.after(7, in: ids, wrap: false) == nil)
      precondition(
        VideoRepeat.one.after(2, in: ids) == nil && VideoRepeat.pause.after(2, in: ids) == nil)
      precondition(
        VideoRepeat.related.after(2, in: ids) == 7 && VideoRepeat.related.after(7, in: ids) == nil
          && VideoRepeat.order.after(9, in: ids) == nil)
    }
    do {
      let sample = Data(
        #"[{"aid":5,"bvid":"BV1xx411c7mD","title":"稿件","progress":-1},{"aid":8,"is_pgc":true,"bangumi":{"ep_id":32}},{"aid":9,"is_pugv":true},{"aid":11,"state":-4},{"aid":12,"is_pgc":true,"redirect_url":"https://www.bilibili.com/bangumi/play/ss3"}]"#
          .utf8)
      let entries = try JSONDecoder().decode([LaterMedia].self, from: sample)
      precondition(
        entries[0].route == .video("BV1xx411c7mD", nil) && entries[0].progressText == "已看完")
      precondition(entries[1].route == .episode(32) && entries[1].resource == 8)
      precondition(
        entries[2].route == .course(9, false) && entries[3].route == nil
          && entries[4].route == .season(3))
    }
    do {
      let d = DynamicModules(
        [
          "module_dispute": ["title": "说明", "jump_url": "https://bilibili.com.unrelated.invalid/"],
          "module_interaction": [
            "items": [["desc": ["rich_text_nodes": [["text": "热评"], ["orig_text": "内容"]]]]]
          ],
        ], major: ["pgc": ["epid": "123", "jump_url": "https://www.bilibili.com/bangumi/play/ss4"]])
      precondition(
        d.attachment?.route == .episode(123) && d.notice?.link == nil && d.interactions == ["热评内容"])
      let c = DynamicModules([:], major: ["courses": ["season_id": 44]])
      precondition(c.attachment?.route == .course(44, false))
    }
    do {
      for (kind, route) in [
        (IMShareCard.Kind.video, SharedLink.archive(91, nil)), (.article, .article(91)),
        (.dynamic, .dynamic("91")), (.episode, .episode(91)), (.live, .room(91)),
      ] {
        let c = IMShareCard(kind, id: "91", title: "示例", author: "作者", authorID: "9")
        let incoming = IMShareCard.incoming(c.messageType, c.body)
        precondition(incoming?.route == route && incoming?.title == "示例")
      }
      precondition(IMShareCard.incoming(14, ["source": "直播", "sourceID": "../room"]) == nil)
      precondition(IMShareCard.incoming(7, ["source": 14, "id": "91"]) == nil)
    }
    do {
      let pm: [String: Int64] = [
        "follow_unread": 2, "biz_msg_unfollow_unread": 7, "dustbin_unread": 10,
      ]
      let feed: [String: Int64] = ["at": 1, "sys_msg": 3, "reply": 5, "like": 12]
      precondition(
        UnreadTotals.messages(31, pm, feed) == 30 && UnreadTotals.messages(0, pm, feed) == 0
          && UnreadTotals.messages(4, pm, feed) == 1)
      precondition(
        UnreadTotals.label(100, mode: 2) == "99+" && UnreadTotals.label(99, mode: 1) == "•"
          && UnreadTotals.label(0, mode: 2) == nil && UnreadTotals.label(1, mode: 0) == nil)
    }
    var draft = ReplyDraft()
    draft.change(to: "👩🏽‍💻 ")
    let first = draft.replace(nil, with: "同名", url: "https://b23.tv/one")
    _ = draft.replace(first, with: "同名", url: "https://b23.tv/two")
    precondition(draft.raw == "👩🏽‍💻 https://b23.tv/one https://b23.tv/two ")
    let a = (draft.text as NSString).range(of: "同名")
    let nextText = (draft.text as NSString).replacingCharacters(in: a, with: "已改")
    draft.change(to: nextText, hint: (a, "已改"))
    precondition(draft.raw == "👩🏽‍💻 已改 https://b23.tv/two ")
    draft.change(to: "🎬" + draft.text)
    precondition(draft.raw == "🎬👩🏽‍💻 已改 https://b23.tv/two ")
    _ = draft.replace(NSRange(location: 0, length: (draft.text as NSString).length), with: "新稿")
    precondition(draft.raw == "新稿")
    let dynOpus: [String: Any] = [
      "title": "原题",
      "summary": [
        "rich_text_nodes": [
          ["type": "RICH_TEXT_NODE_TYPE_AT", "orig_text": "@猫", "rid": "92"],
          ["type": "RICH_TEXT_NODE_TYPE_TEXT", "orig_text": " ok"],
        ]
      ],
      "pics": [
        ["url": "https://i0.hdslb.com/a", "width": 10, "height": 20, "live_url": "motion"]
          as [String: Any]
      ],
    ]
    let dynModules: [String: Any] = [
      "module_author": ["mid": "7", "badge_text": "仅自己可见"],
      "module_dynamic": ["major": ["opus": dynOpus]],
    ]
    let dynRow: [String: Any] = [
      "id_str": "88", "type": "DYNAMIC_TYPE_DRAW", "modules": dynModules,
    ]
    let original = try DynamicRevision(row: dynRow, expected: "7", id: "88")
    var editing = original.editor()
    editing.change(to: "新：" + editing.text)
    let result = original.payload(
      contents: editing.pieces, title: "新题", pictures: original.pictures.map(\.wire), topicID: nil,
      topicName: nil, isPrivate: original.privateOnly, replyMode: -1, uploadID: "test")
    let req = result["dyn_req"] as! [String: Any]
    let content = req["content"] as! [String: Any]
    let chunks = content["contents"] as! [[String: Any]]
    precondition(
      result["dyn_id_str"] as? String == "88" && req["scene"] as? Int == 2 && chunks.count == 3
        && chunks[1]["biz_id"] as? String == "92")
    precondition(
      (req["option"] as? [String: Int])?["private_pub"] == 1
        && (req["option"] as? [String: Int])?["close_comment"] == nil)
    precondition((req["pics"] as? [[String: Any]])?.first?["live_url"] as? String == "motion")
    precondition((try? DynamicRevision(row: dynRow, expected: "8", id: "88")) == nil)
    precondition(
      FullscreenMode.ratio.wanted(
        videoWidth: 1920, videoHeight: 1080, screenWidth: 1010, screenHeight: 1000) == .portrait)
    precondition(
      FullscreenMode.video.wanted(
        videoWidth: 1080, videoHeight: 1920, screenWidth: 400, screenHeight: 800) == .portrait)
    precondition(
      FullscreenMode.keep.wanted(
        videoWidth: 1920, videoHeight: 1080, screenWidth: 400, screenHeight: 800) == nil)
    precondition(PlayerSlide.axis(dx: 9, dy: 4, x: 40, width: 300, levels: true, screen: true) == nil)
    precondition(PlayerSlide.axis(dx: 14, dy: 4, x: 40, width: 300, levels: false, screen: false) == .seek)
    precondition(PlayerSlide.axis(dx: 0, dy: 20, x: 270, width: 300, levels: false, screen: true) == nil)
    precondition(PlayerSlide.axis(dx: 0, dy: 20, x: 150, width: 300, levels: false, screen: true) == .fullscreen)
    precondition(PlayerSlide.level(0.5, dy: 60, height: 120, brightness: false) == 0)
    precondition(abs(PlayerSlide.level(0.5, dy: 60, height: 120, brightness: true) - 1 / 3) < 0.00001)
    precondition(
      FullscreenMode.swipe(fullscreen: false, reverse: false, x: 150, width: 300, dx: 5, dy: -40))
    precondition(
      !FullscreenMode.swipe(fullscreen: true, reverse: false, x: 150, width: 300, dx: 5, dy: -40))
    precondition(
      FullscreenMode.swipe(fullscreen: true, reverse: true, x: 150, width: 300, dx: 5, dy: -40))
    precondition(
      !FullscreenMode.swipe(fullscreen: false, reverse: false, x: 20, width: 300, dx: 5, dy: -40))
    var capture = CaptureTiming(seconds: 1, fps: 5)
    let decisions = try [10.0, 10.01, 10.20, 10.40, 10.60, 10.80, 11.0].map { try capture.next($0) }
    precondition(decisions == [.capture, .skip, .capture, .capture, .capture, .capture, .complete])
    precondition(abs(capture.delays().reduce(0, +) - 1) < 0.01)
    do {
      _ = try capture.next(0)
      preconditionFailure("seek joined unrelated frames")
    } catch {}
    var ranged = SponsorDraft(end: 8)
    ranged.start = 1
    var highlight = SponsorDraft(end: 0)
    highlight.start = 4
    highlight.select("poi_highlight")
    var whole = SponsorDraft(end: 0)
    whole.select("exclusive_access")
    let shapes = try SponsorDraft.payload([ranged, highlight, whole], duration: 15).map {
      $0["segment"] as! [Double]
    }
    precondition(shapes == [[1, 8], [4, 4], [0, 0]])
    do {
      _ = try SponsorDraft.payload([ranged, .init(end: 16)], duration: 15)
      preconditionFailure("accepted invalid batch")
    } catch {}
    var sb = SponsorRules()
    sb.minimum = 2
    sb.modes[1] = 0
    sb.modes[3] = 2
    let ad = SponsorSegment(category: "sponsor", actionType: "skip", segment: [3, 9], UUID: "a")
    let repeatAd = SponsorSegment(
      category: "selfpromo", actionType: "skip", segment: [12, 20], UUID: "b")
    let point = SponsorSegment(
      category: "poi_highlight", actionType: "poi", segment: [10, 10], UUID: "p")
    var trips = SponsorVisits()
    precondition(sb.mode(point) == 3 && trips.next([ad, repeatAd], time: 3, rules: sb)?.id == "a")
    precondition(
      trips.next([ad, repeatAd], time: 3.1, rules: sb) == nil
        && trips.next([ad, repeatAd], time: 10, rules: sb) == nil)
    precondition(
      trips.next([ad, repeatAd], time: 4, rules: sb) == nil
        && trips.next([ad, repeatAd], time: 12, rules: sb)?.id == "b")
    _ = trips.next([ad, repeatAd], time: 21, rules: sb)
    precondition(trips.next([ad, repeatAd], time: 13, rules: sb)?.id == "b")
    let shots = try JSONDecoder().decode(
      ShotMap.self,
      from: Data(
        #"{"img_x_len":2,"img_y_len":2,"img_x_size":160,"img_y_size":90,"image":["a","b"],"index":[0,0,7,13,16,20,25]}"#
          .utf8))
    precondition(
      shots.tile(0)?.x == 0 && shots.tile(6)?.x == 0 && shots.tile(7)?.x == 160
        && shots.tile(13)?.y == 90)
    precondition(shots.tile(20) == ShotMap.Tile(image: "b", x: 0, y: 0, width: 160, height: 90))
    let trend = try ActivityTrend.parse(
      Data(
        #"{"modules":[{"params":{"data":{"step_sec":2,"events":{"default":[2,6,1,4]}}}},{"other":true}]}"#
          .utf8))
    precondition(trend.peaks(columns: 2, duration: 8) == [1, 4.0 / 6.0])
    if CommandLine.arguments.count == 3 {
      struct Envelope: Decodable { let data: ShotMap }
      let realShots = try JSONDecoder().decode(
        Envelope.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
      ).data
      let realTrend = try ActivityTrend.parse(
        Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
      precondition(realShots.tile(0)?.image != realShots.tile(Double(realShots.times.last!))?.image)
      precondition(!realTrend.peaks(columns: 160, duration: Double(realShots.times.last!)).isEmpty)
      print(
        "Public video: \(realShots.images.count) sheets, \(realShots.times.count) timestamps, \(realTrend.events.values.count) trend samples"
      )
    }
    var routes = AccountRoutes()
    let uids: Set<String> = ["1", "2", "3"]
    func routed(_ p: String, _ host: String = "api.bilibili.com") -> String? {
      routes.owner(AccountRoutes.service(p, host: host), main: "1", available: uids)
    }
    routes.set(.video, choice: "2")
    routes.set(.recommend, choice: "3")
    let privateView = routes.privatePlaybackCopy()
    precondition(privateView.owner(.role(.heartbeat), main:"1", available:uids) == nil)
    precondition(privateView.owner(.history, main:"1", available:uids) == "1")
    precondition(privateView.owner(.role(.video), main:"1", available:uids) == routes.owner(.role(.video), main:"1", available:uids))
    precondition(routes.choice(.heartbeat) != AccountRoutes.guest)
    routes.set(.heartbeat, choice: AccountRoutes.guest)
    precondition(
      routed("/x/player/wbi/playurl") == "2"
        && routed("/x/web-interface/wbi/index/top/feed/rcmd") == "3")
    precondition(
      routed("/x/click-interface/web/heartbeat") == nil
        && routed("/x/web-interface/history/cursor") == "1")
    precondition(
      routed("/x/v2/history/toview/add") == "1"
        && routed("/xlive/web-room/v1/index/getDanmuInfo", "api.live.bilibili.com") == nil)
    routes.set(.heartbeat, choice: "2")
    precondition(routed("/x/v2/history/delete") == "2" && routed("/x/v2/reply/add") == "1")
    routes.remove("2")
    precondition(
      routed("/x/player/wbi/playurl") == nil && routed("/x/web-interface/history/cursor") == "1")
    var media = NetworkMediaRules.legacy(video: 116, audio: 30232, codec: "hev1")
    precondition(
      media.wifiVideo == 116 && media.cellVideo == 80
        && media.codecOrder(cellular: true) == ["HEVC"])
    media.cellCodecs = ["AV1", "AVC"]
    try media.save(defaults)
    precondition(NetworkMediaRules.current(defaults) == media)
    precondition(
      NetworkMediaRules.target(
        [30216, 30280, 30251], target: 30, score: NetworkMediaRules.audioRank) == 30216)
    precondition(
      NetworkMediaRules.target([30251, 30255], target: 20, score: NetworkMediaRules.audioRank)
        == 30255)
    let stream: [String: Any] = [
      "id": 30216, "codecs": "mp4a.40.2", "bandwidth": 64000, "base_url": "https://example.org/a",
      "segment_base": ["initialization": "0-11", "index_range": "12-45"],
    ]
    do {
      let mixed = stream.merging(["width": 1920, "height": 1080, "frame_rate": "60000/1001"]) { $1 }
      let v = try JSONDecoder().decode(
        DashStream.self, from: JSONSerialization.data(withJSONObject: mixed))
      let attributes = v.masterAttributes(audio: nil)
      precondition(
        attributes.contains("RESOLUTION=1920x1080") && attributes.contains("FRAME-RATE=59.940"))
      let bad = mixed.merging(["frame_rate": "60/0", "width": -1]) { $1 }
      let invalid = try JSONDecoder().decode(
        DashStream.self, from: JSONSerialization.data(withJSONObject: bad))
      precondition(
        !invalid.masterAttributes(audio: nil).contains("FRAME-RATE")
          && !invalid.masterAttributes(audio: nil).contains("RESOLUTION"))
    }
    func track(_ id: Int, _ codecs: String) -> [String: Any] {
      stream.merging(["id": id, "codecs": codecs]) { $1 }
    }
    let manifest: [String: Any] = [
      "video": [track(80, "avc1.640028")], "audio": [stream],
      "dolby": ["audio": [track(30250, "ec-3")]], "flac": ["audio": track(30251, "fLaC")],
    ]
    let dash = try JSONDecoder().decode(
      DashFormats.self, from: JSONSerialization.data(withJSONObject: manifest))
    precondition(
      dash.advertisedAudio && dash.video.first?.SegmentBase.indexRange == "12-45"
        && Set((dash.audio ?? []).map(\.id)) == [30216, 30250, 30251])
    let unsupported = try JSONDecoder().decode(
      DashFormats.self, from: Data(#"{"video":[],"audio":[{"id":30216}]}"#.utf8))
    precondition(unsupported.advertisedAudio && unsupported.audio?.isEmpty == true)
    var commentRules = ReplyFilterRules()
    commentRules.mentionsOnly = true
    commentRules.threshold = 3
    commentRules.pattern = "spam[0-9]"
    commentRules.duplicateIntro = true
    commentRules.goods = true
    try commentRules.save(defaults)
    let commentFilter = ReplyFilter(rules: .current(defaults), blocked: [42], intro: "简介")
    func hidden(
      _ msg: String, _ names: Set<String> = [], child: Bool = false, media: Bool = false,
      goods: Bool = false, mid: Int64 = 1
    ) -> Bool {
      commentFilter.hides(
        author: mid, body: msg, mentions: names, hasMedia: media, hasGoods: goods, nested: child)
    }
    precondition(hidden("@甲@乙", ["甲", "乙"]) && hidden("回复 @甲: @乙", ["乙"], child: true))
    precondition(
      !hidden("@未知", ["甲"]) && !hidden("@甲 谢谢", ["甲"]) && !hidden("@甲", ["甲"], media: true))
    precondition(
      hidden("消息", ["甲", "乙", "丙"]) && hidden(" 简介\n") && hidden("SPAM7") && hidden("消息", mid: 42))
    precondition(
      hidden("商品", goods: true) && hidden("https://gaoneng.bilibili.com/tetris/x")
        && !hidden("普通评论"))
    var mentionLimit = ReplyFilterRules()
    mentionLimit.threshold = 0
    let suppressAll = ReplyFilter(rules: mentionLimit, blocked: [], intro: nil)
    precondition(suppressAll.hides(author: nil, body: "普通评论", mentions: [], hasMedia: false, hasGoods: false, nested: false))
    mentionLimit.threshold = nil
    let allowed = ReplyFilter(rules: mentionLimit, blocked: [], intro: nil)
    precondition(!allowed.hides(author: nil, body: "@甲", mentions: ["甲"], hasMedia: false, hasGoods: false, nested: false))
    var rules = RecommendationRules()
    rules.minimumSeconds = 60
    rules.minimumViews = 200
    rules.minimumLikePercent = 5
    rules.titlePattern = "Spoiler"
    rules.zonePattern = "sports"
    rules.blockedCreators = [42]
    try rules.save(defaults)
    precondition(RecommendationRules.current(defaults) == rules)
    var f = RecommendationFilter(rules)
    func visible(
      _ source: RecommendationFilter.Source, _ s: Int = 60, _ views: Int = 200, _ likes: Int = 10,
      _ title: String = "ok", _ zone: String = "ok", _ follows: Bool = false, _ owner: Int64 = 1
    ) -> Bool {
      f.includes(
        title: title, zone: zone, seconds: s, views: views, likes: likes, followed: follows,
        creator: owner, source: source)
    }
    precondition(visible(.feed) && !visible(.feed, 59) && visible(.hotOrRank, 1))
    precondition(!visible(.feed, 60, 199) && !visible(.feed, 60, 200, 9))
    precondition(
      !visible(.feed, 60, 200, 10, "SPOILER") && !visible(.hotOrRank, 60, 200, 10, "ok", "SPORTS"))
    precondition(
      visible(.feed, 1, 1, 0, "spoiler", "sports", true)
        && !visible(.feed, 60, 200, 10, "ok", "ok", true, 42))
    precondition(!visible(.mobileFeed,60,200,10,"ok","SPORTS"))
    precondition(!visible(.mobileFeed,1,1,0,"spoiler","sports",true))
    precondition(visible(.mobileFeed,1,1,0,"spoiler","ok",true))
    precondition(!visible(.mobileFeed,59) && !visible(.mobileFeed,60,199))
    precondition(visible(.feed,60,200,10,"ok","sports") && visible(.related,60,200,10,"ok","sports"))
    precondition(!visible(.related, 1))
    rules.filterRelated = false
    f = RecommendationFilter(rules)
    precondition(visible(.related, 1))
    precondition(!visible(.related, 60, 200, 10, "ok", "ok", false, 42))
    rules.titlePattern = "["
    do {
      try rules.save(defaults)
      fatalError("Invalid regex persisted")
    } catch {}
    precondition(RecommendationRules.current(defaults).titlePattern == "Spoiler")

    let now = Date(timeIntervalSince1970: 50)
    var timer = SleepDeadline.scheduled(now, afterItem: true)
    precondition(!timer.expire(now: now.addingTimeInterval(-1), playing: true, live: false))
    precondition(!timer.expire(now: now, playing: true, live: false) && timer == .finishingItem)
    precondition(timer.finish() && !timer.finish())
    for (playing, live) in [(true, true), (false, false)] {
      timer = .scheduled(now, afterItem: true)
      precondition(timer.expire(now: now, playing: playing, live: live) && timer == .off)
    }
    let clip = EpisodeClip(clipType: "CLIP_TYPE_OP", start: 2, end: 10)
    precondition(!clip.contains(1) && clip.contains(2) && !clip.contains(10))
    var skips = EpisodeSkipHistory()
    precondition(skips.target(clip, mode: .manual) == nil && skips.target(clip, mode: .once) == 10)
    precondition(skips.target(clip, mode: .once) == nil && skips.target(clip, mode: .always) == 10)
    skips = EpisodeSkipHistory()
    precondition(skips.target(clip, mode: .once) == 10)
    precondition(
      skips.target(EpisodeClip(clipType: "OTHER", start: 0, end: 5), mode: .always) == nil)

    let wanted = "bytes=10-29"
    for bad in [
      "bytes 11-29/30", "bytes 10-28/30", "bytes 10-29/27", "bytes 10-29/*", "bytes 10-29/-3",
      "items 10-29/30", "bytes +10-29/30",
    ] {
      precondition(MediaRange(field: bad, request: wanted, declared: -1) == nil)
    }
    precondition(MediaRange(field: "bytes 10-29/30", request: wanted, declared: 19) == nil)
    var range = MediaRange(field: "bytes 10-19/20", request: wanted, declared: 10)!
    precondition(
      range.accept(4) && !range.complete && !range.accept(7) && range.accept(6) && range.complete)
    precondition(MediaRange(field: "bytes 9-9/10", request: "bytes=-1", declared: -1)?.length == 1)
    print(
      "PASS feed-policy persistence, clock and episode boundaries, CDN byte ranges and transfer lengths"
    )
  }
}
