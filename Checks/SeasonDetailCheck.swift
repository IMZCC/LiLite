import Foundation

@main struct SeasonDetailCheck {
  typealias Map = [String: Any]
  static func bytes(_ o: Any) throws -> Data { try JSONSerialization.data(withJSONObject: o) }
  static func decode<T: Decodable>(_ t: T.Type, _ m: Map) throws -> T {
    try JSONDecoder().decode(T.self, from: bytes(m))
  }
  static func check(_ b: Bool, _ s: String) { precondition(b, s) }
  static func rejected(_ f: () throws -> Void) -> Bool {
    do {
      try f()
      return false
    } catch { return true }
  }
  static func main() throws {
    let main: Map = ["ep_id": 11, "id": 99, "cid": 101, "title": "正片", "aid": 170001]
    let extra: Map = ["id": 12, "cid": 102, "title": "预告", "show_title": "花絮特辑"]
    let s = try decode(
      SeasonInfo.self,
      [
        "title": "作品", "season_id": 10, "episodes": [main, ["id": 13, "cid": 0]],
        "section": [["title": "预告", "episodes": [extra, extra]], ["title": "空"]],
        "user_status": ["progress": ["last_ep_id": 12]],
        "seasons": [
          ["season_id": 10, "season_title": "第一季"], ["season_id": 20, "season_title": "第二季"],
        ],
      ])
    check(s.groups.count == 2 && s.seasons?.count == 2, "season groups")
    check(
      s.locate(11)?.1.queue.map(\.id) == [11] && s.locate(12)?.1.queue.map(\.id) == [12]
        && s.locate(99) == nil, "PGC canonical ids, local queues")
    check(
      s.resume?.0.label == "花絮特辑" && s.locate(13)?.0.canRequestPlayback == false
        && s.locate(11)?.0.bvid == ArchiveNumber.bv(170001), "resume/disabled slot")
    let local: Map = [
      "season_id": 15, "title": "章节",
      "episodes": [
        ["id": 11, "cid": 4, "playable": false], ["id": 14, "cid": 6, "playable": true],
      ],
      "sections": [
        [
          "section_type": 1, "title": "默认",
          "episodes": [
            ["id": 11, "cid": 4, "playable": true],
            [
              "id": 12, "cid": 5, "episode_can_view": true, "preview_toast": "试看中，购买即可观看完整内容",
              "watchedHistory": 28,
            ], ["id": 13, "cid": 9, "play_way": 2],
            ["id": 14, "cid": 6, "episode_can_view": false], ["id": 15, "cid": 8],
          ],
        ]
      ],
      "ep_catalogue": [
        ["index": 1, "title": "初级", "start_ep_index": 1, "end_ep_index": 2],
        ["index": 2, "title": "后续", "start_ep_index": 2, "end_ep_index": 4],
      ],
    ]
    let l = try decode(CourseCatalog.self, local)
    check(
      l.groups.map(\.title) == ["初级", "后续", "其他课时"],
      "catalogue is 1-based and overlaps do not duplicate lessons")
    check(l.lessons.map(\.id) == [11, 12, 13, 14, 15], "preserve published order")
    check(
      !l.lessons[0].canRequestPlayback && l.lessons[1].preview && !l.lessons[1].allowCacheEntry
        && l.continueSeconds(for: l.lessons[1]) == 28 && !l.lessons[2].canRequestPlayback
        && !l.lessons[3].canRequestPlayback,
      "old denial, current preview, live class, per-unit access")
    var drm = local
    drm["drm_switch"] = 1
    let protected = try decode(CourseCatalog.self, drm)
    check(
      protected.lessons.allSatisfy { !$0.canRequestPlayback && !$0.allowCacheEntry },
      "course protected")
    let geo = try decode(
      SeasonInfo.self,
      [
        "title": "区域", "season_id": 9, "rights": ["area_limit": 328, "can_watch": 1],
        "user_status": ["area_limit": 1], "episodes": [main],
      ])
    let world = try decode(
      SeasonInfo.self,
      [
        "title": "区域", "season_id": 9, "rights": ["area_limit": 328, "can_watch": 1],
        "user_status": ["area_limit": 0], "episodes": [main],
      ])
    check(
      geo.resume == nil && world.resume?.0.id == 11,
      "region rights are contextual; the broad area mask is not viewer denial")
    let missing = try decode(
      SeasonInfo.Episode.self, ["id": 80, "cid": 0, "aid": 170001, "page": 2])
    check(
      missing.canResolveCID && !missing.canRequestPlayback,
      "missing cid may look up metadata but is not a media grant")
    if CommandLine.arguments.count == 4 {
      let pub = try JSONDecoder().decode(
        SeasonInfo.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
      let v1 = try JSONDecoder().decode(
        CourseCatalog.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
      var v2 = try JSONDecoder().decode(
        CourseCatalog.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
      precondition(v1.season_id == v2.season_id)
      v2.episodes = v1.episodes
      print(
        "public metadata: season", pub.season_id ?? 0, "groups", pub.groups.count, "episodes",
        pub.groups.flatMap(\.episodes).count, "staff chars", pub.staff?.count ?? 0, "course",
        v2.season_id, "sections", v2.groups.count, "lessons", v2.lessons.count, "restricted",
        v2.lessons.filter { !$0.canRequestPlayback }.count, "preview",
        v2.lessons.filter { $0.preview && $0.canRequestPlayback }.count)
    }
    let courseFields = l.lessons[1].historyFields(course:true,seasonID:15,seasonType:nil)
    check(courseFields["type"]=="10" && courseFields["sid"]=="15" && courseFields["epid"]=="12" && courseFields["sub_type"]==nil,"class history uses course and episode IDs")
    let episodeFields=world.locate(11)!.0.historyFields(course:false,seasonID:9,seasonType:4)
    check(episodeFields["type"]=="4" && episodeFields["sub_type"]=="4" && episodeFields["sid"]=="9" && episodeFields["bvid"]==ArchiveNumber.bv(170001),"PGC subtype on heartbeat")
    let c = try decode(
      CourseCatalog.self,
      [
        "season_id": 22, "title": "课",
        "episodes": [
          main, ["id": 23, "cid": 200, "is_preview": true, "aid": 1],
          ["id": 24, "cid": 201, "playable": 0],
          ["id": 25, "cid": 202, "rights": ["allow_download": 0]],
        ], "user_status": ["progress": ["last_ep_id": 23]],
      ])
    check(
      c.lessons.map(\.id) == [99, 23, 24, 25] && c.preferred(episode: nil, aid: 170001)?.id == 99
        && c.preferred(episode: 400, aid: nil) == nil, "PUGV id and exact routing")
    check(
      c.preferred(episode: nil, aid: nil)?.id == 23
        && c.lessons.filter(\.allowCacheEntry).map(\.id) == [99]
        && c.lessons.compactMap(\.playItem).map(\.id) == [99, 23, 25],
      "trial playback, lock, offline")
    check(
      EpisodeCachePolicy.episodeID(main, course: false) == 11
        && EpisodeCachePolicy.episodeID(main, course: true) == 99, "cache identity")
    for denied in [["is_preview": 1], ["can_watch": 0], ["area_limit": 1], ["allow_download": 0]] {
      check(
        rejected {
          try EpisodeCachePolicy.allow(
            series: ["rights": ["allow_download": 1]], episode: ["rights": denied], vip: true)
        }, "grant not expanded")
    }
    check(
      rejected {
        try EpisodeCachePolicy.allow(series: ["allow_download": -1], episode: [:], vip: false)
      }, "unknown grant never treated as permission")
    let dash: Map = ["video": [], "audio": []]
    check(EpisodePlayPayload.requestsWebFallback(try bytes(["code": 0, "data": ["arc": ["is_drm": true]]])), "normal playview web routing marker")
    for payload: Map in [
      ["code": -403, "data": ["arc": ["is_drm": true]]],
      ["code": 0, "data": ["arc": ["is_drm": true], "not_playable_reason": ["code": 1, "message": "拒绝"]]],
      ["code": 0, "data": ["arc": ["is_drm": true], "video_info": ["dash": dash]]],
    ] {
      check(!EpisodePlayPayload.requestsWebFallback(try bytes(payload)), "no fallback for refusal or supplied media")
    }
    let result = try EpisodePlayPayload(
      bytes([
        "code": 0,
        "data": [
          "video_info": [
            "dash": dash, "accept_description": ["试看"],
            "clip_info_list": [["clipType": "CLIP_TYPE_OP", "start": 1.0, "end": 5.0]],
          ]
        ],
      ]))
    switch result.route {
    case .play(let i): check(i.preview && i.clips.count == 1, "parse server preview")
    default: preconditionFailure("should offer preview")
    }
    let segments: [Map] = [
      ["order": 2, "url": "https://media.example.test/two.flv", "length": 6000],
      ["order": 1, "url": "https://media.example.test/one.mp4", "length": 4000],
    ]
    let progressive: Map = ["durl": segments, "quality": 80, "accept_quality": [80, 64]]
    let clearMarker: Map = ["arc": ["is_drm": true], "video_info": progressive]
    let clearReply = try EpisodePlayPayload(bytes(["code": 0, "data": clearMarker]))
    guard case .play = clearReply.route else { preconditionFailure("clear routed media rejected") }
    _ = try EpisodeCachePolicy.clearPayload(clearMarker)
    check(EpisodePlayPayload.preview(try bytes(["code": 0, "data": ["arc": ["is_drm": true, "is_preview": true]]])), "preview retained across web route")
    for (envelope, legacy): (Map, Bool) in [
      (["code": 0, "data": ["video_info": progressive]], false),
      (["code": 0, "result": progressive], true),
      (["code": 0, "data": progressive], false),
    ] {
      let reply = try EpisodePlayPayload(bytes(envelope), legacy: legacy)
      guard case .play(let info) = reply.route else { preconditionFailure("legal durl refused") }
      let parts = try info.legacy.parts
      check(parts.count == 2 && parts[0].order == 1 && parts[1].order == 2 && info.quality == 80, "ordered legacy PGC/course delivery")
      _ = try EpisodeCachePolicy.clearPayload(["video_info": progressive])
    }
    for denied: Map in [
      ["durl": [["url": "https://media.example.test/protected.flv", "license_url": "fixture"]]],
      ["durl": segments, "is_preview": true],
      ["durl": segments, "is_drm": true],
    ] {
      check(rejected { _ = try EpisodeCachePolicy.clearPayload(denied) }, "legacy cache rights retained")
    }
    let protectedLegacy = try EpisodePlayPayload(bytes(["code": 0, "result": ["durl": [["url": "https://media.example.test/protected.flv", "license_url": "fixture"]]]]), legacy: true)
    if case .play = protectedLegacy.route { preconditionFailure("protected legacy stream") }
    for data: Map in [
      ["not_playable_reason": ["code": 1, "message": "此账号未解锁"], "video_info": ["dash": dash]],
      ["arc": ["license_url": "fixture"], "video_info": ["dash": dash]],
      ["video_info": ["dash": ["video": [], "dolby": ["audio": [["license_url": "fixture"]]]]]],
    ] {
      let body = try EpisodePlayPayload(bytes(["code": 0, "data": data]))
      if case .play = body.route { preconditionFailure("protected stream") }
    }
    check(
      EpisodeCachePolicy.denial(["not_playable_reason": ["code": 0, "message": ""]]) == nil
        && EpisodeCachePolicy.denial(["not_playable_reason": ["code": "4", "message": "拒绝"]])
          == "拒绝",
      "neutral reason vs refusal")
    let negative = try EpisodePlayPayload(bytes(["code": -403, "message": "denied"]))
    if case .play = negative.route { preconditionFailure("business refusal") }
    for data: Map in [
      ["dash": dash, "accept_description": ["试看"]],
      ["arc": ["license_url": "fixture"], "video_info": ["dash": dash]],
      ["dash": ["video": [], "flac": ["audio": ["pssh": "fixture"]]]],
    ] {
      check(rejected { _ = try EpisodeCachePolicy.clearMedia(data) }, "offline preview or DRM")
    }
    let r = try decode(
      SeasonReview.self,
      ["review_id": 17, "score": 8, "author": ["mid": 33], "stat": ["liked": 1, "likes": 5]])
    check(
      SeasonReviewPolicy.post(media: 20, stars: 4, body: "", share: true, editing: nil, owner: "33")
        == ["media_id": "20", "score": "8", "content": "", "share_feed": "1"], "rating without text"
    )
    check(
      SeasonReviewPolicy.post(
        media: 20, stars: 5, body: String(repeating: "好", count: 101), share: false, editing: nil,
        owner: "33") == nil, "100 character limit")
    check(
      SeasonReviewPolicy.post(media: 20, stars: 3, body: "x", share: true, editing: r, owner: "44")
        == nil
        && SeasonReviewPolicy.post(
          media: 20, stars: 3, body: "x", share: true, editing: r, owner: "33")?["share_feed"]
          == nil
        && r.stars == 4 && r.stat?.liked == 1, "edit identity and share")
    check(
      SeasonReviewPolicy.report(17, media: 20)?.host == "www.bilibili.com"
        && SeasonReviewPolicy.longEditor(media: 20, dark: true)?.query?.contains("theme=1") == true,
      "official review destinations")
    print(
      "episode catalog: season/section queues, separate course IDs, resume, access/preview/cache, review ownership and exact score payloads passed"
    )
  }
}
