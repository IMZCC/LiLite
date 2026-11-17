import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@_silgen_name("MD5") private func opensslMD5(
  _ bytes: UnsafeRawPointer?, _ count: Int, _ out: UnsafeMutablePointer<UInt8>
) -> UnsafeMutablePointer<UInt8>?
// Optional read-only check. No Cookie header, disk cache or login storage is used.
@main enum PublicServiceCheck {
  struct Envelope<T: Decodable>: Decodable { let data: T?, result: T? }
  struct Status: Decodable {
    let code: Int
    let message: String?
  }
  struct VideoList: Decodable { let list: [Video] }
  struct SeriesList: Decodable { let list: [Season] }
  struct Trends: Decodable {
    let trending: Trending
    struct Trending: Decodable { let list: [Trend] }
    struct Trend: Decodable { let keyword: String }
  }
  enum Problem: Error, CustomStringConvertible {
    case status(String), empty, contract(String)
    var description: String {
      switch self {
      case .status(let s): return s
      case .empty: return "empty sample"
      case .contract(let s): return s
      }
    }
  }
  static func get<T: Decodable>(
    _ host: String = "api.bilibili.com", _ path: String, _ fields: [String: String], _: T.Type
  ) async throws -> T {
    var c = URLComponents()
    c.scheme = "https"
    c.host = host
    c.path = path
    c.queryItems = fields.map(URLQueryItem.init)
    guard let url = c.url else { throw URLError(.badURL) }
    var r = URLRequest(url: url, timeoutInterval: 12)
    r.httpShouldHandleCookies = false
    r.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    r.setValue(
      "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Version/17.0 Mobile/15E148 Safari/604.1",
      forHTTPHeaderField: "User-Agent")
    let conf = URLSessionConfiguration.ephemeral
    conf.urlCache = nil
    conf.httpShouldSetCookies = false
    conf.httpCookieStorage = nil
    let session = URLSession(configuration: conf)
    defer { session.finishTasksAndInvalidate() }
    let (d, http) = try await session.data(for: r)
    guard let h = http as? HTTPURLResponse, h.statusCode == 200 else {
      throw Problem.status("HTTP \((http as? HTTPURLResponse)?.statusCode ?? 0)")
    }
    let decoder = JSONDecoder()
    let status = try decoder.decode(Status.self, from: d)
    guard status.code == 0 || (path == "/x/web-interface/nav" && status.code == -101) else {
      throw Problem.status("service code \(status.code)")
    }
    let payload = try decoder.decode(Envelope<T>.self, from: d)
    guard let value = payload.data ?? payload.result else { throw Problem.empty }
    return value
  }
  static func signed(_ q: [String: String]) async throws -> [String: String] {
    let api = "api.bilibili.com"
    let nav = try await get(api, "/x/web-interface/nav", [:], WebQuery.Keys.self)
    let mix = try WebQuery.mix(nav.wbi_img)
    return WebQuery.signed(q, mix: mix) { d in
      var digest = [UInt8](repeating: 0, count: 16)
      d.withUnsafeBytes { p in _ = opensslMD5(p.baseAddress, p.count, &digest) }
      return digest.map { String(format: "%02x", $0) }.joined()
    }
  }
  static func main() async {
    var failures = 0
    func check(_ name: String, _ run: () async throws -> String) async {
      do { print("PASS \(name):", try await run()) } catch {
        failures += 1
        print("NOT VERIFIED \(name):", error)
      }
    }
    if ProcessInfo.processInfo.environment["PILI_PUBLIC_QUALITY"] == "1" {
      await check("regular guest quality response") {
        struct Play: Decodable { let dash: DashFormats? }
        let q = try await signed(["bvid":"BV1fK4y1t7hj","cid":"196018899","qn":"80","fnval":"4048","fnver":"0"])
        let response = try await get("api.bilibili.com", "/x/player/wbi/playurl", q, ArchiveGrantResponse<Play>.self)
        let ids = Set((response.body.dash?.video ?? []).filter { response.grant.permits($0.id, guest: true) }.map(\.id)).sorted()
        guard !ids.isEmpty else { throw Problem.empty }
        return "public qualities \(ids), preview \(response.grant.preview); no media downloaded"
      }
      exit(failures == 0 ? 0 : 1)
    }
    if ProcessInfo.processInfo.environment["PILI_VOD_LINES"] == "1" {
      await check("public CDN sample") {
        struct Play: Decodable { let dash: DashFormats? }
        let q = try await signed([
          "bvid": "BV1fK4y1t7hj", "cid": "196018899", "qn": "127", "fnver": "0", "fnval": "4048",
          "fourk": "1",
        ])
        let result = try await get("api.bilibili.com", "/x/player/wbi/playurl", q, Play.self)
        guard let video = result.dash?.video.first, let audio = result.dash?.audio?.first else {
          throw Problem.empty
        }
        let client = RangeTransport()
        let ref = URL(string: "https://www.bilibili.com/video/BV1fK4y1t7hj/")!
        defer { client.close() }
        var samples: [String] = []
        for (name, stream) in [("video", video), ("audio", audio)] {
          let originals = VODLine.originals(stream.originals)
          guard !originals.isEmpty else { throw Problem.empty }
          var success = false
          var failures: [String] = []
          for url in originals.prefix(3) {
            do {
              let measured = try await VODSpeedProbe.sample(url, reference: ref, via: client)
              samples.append(
                "\(name): \(measured.bytes) bytes, \(Int(measured.bytesPerSecond)) bytes/s")
              success = true
              break
            } catch let e as RangeHTTPStatus { failures.append("HTTP " + String(e.code)) } catch {
              failures.append("error " + String((error as NSError).code))
            }
          }
          guard success else {
            throw Problem.contract(
              "no usable " + name + " byte range: " + failures.joined(separator: ", "))
          }
        }
        return samples.joined(separator: "; ")
      }
      if failures != 0 { exit(1) }
      return
    }
    if ProcessInfo.processInfo.environment["PILI_MOBILE_FEED"] == "1" {
      await check("mobile recommendation cards") {
        var ids = Set<String>()
        var counts = [Int]()
        var menus = 0
        for page in 1...2 {
          let feed = try await get(
            "app.bilibili.com", "/x/v2/feed/index", MobileFeed.fields(page: page), MobileFeed.self)
          let videos = feed.items.compactMap(\.video)
          guard !videos.isEmpty else { throw Problem.empty }
          counts.append(videos.count)
          ids.formUnion(videos.map(\.id))
          menus +=
            videos.filter {
              $0.recommendMenu?.contains(where: { !($0.reasons ?? []).isEmpty }) == true
            }.count
        }
        return "playable per request " + String(describing: counts) + "; distinct "
          + String(ids.count) + "; menus " + String(menus)
      }
      if failures != 0 { exit(1) }
      return
    }
    if let bv = ProcessInfo.processInfo.environment["PILI_CHECK_PUBLIC_REPLY"] {
      await check("public comment visibility") {
        struct V: Decodable { let aid: Int64 }
        struct R: Decodable { let rpid: Int64 }
        struct List: Decodable { let replies: [R]?, root: R? }
        let v = try await get("api.bilibili.com", "/x/web-interface/view", ["bvid": bv], V.self)
        let p = try await get(
          "api.bilibili.com", "/x/v2/reply/main",
          ["oid": String(v.aid), "type": "1", "mode": "2", "pagination_str": #"{"offset":""}"#],
          List.self)
        guard let reply = p.replies?.first else { throw Problem.empty }
        let q = try await get(
          "api.bilibili.com", "/x/v2/reply/reply",
          ["oid": String(v.aid), "type": "1", "root": String(reply.rpid), "pn": "1", "ps": "20"],
          List.self)
        guard q.root?.rpid == reply.rpid else {
          throw Problem.contract("guest root identity mismatch")
        }
        return "same root visible in guest list and detail; children "
          + String(q.replies?.count ?? 0)
      }
      if failures != 0 { exit(1) }
      return
    }
    if let bv = ProcessInfo.processInfo.environment["PILI_PART_RESUME"] {
      await check("public archive part metadata") {
        struct Part: Decodable { let cid: Int64, page: Int }
        struct V: Decodable { let pages: [Part] }
        struct P: Decodable { let last_play_cid: Int64?, last_play_time: Int64? }
        let v = try await get("api.bilibili.com", "/x/web-interface/view", ["bvid": bv], V.self)
        guard let first = v.pages.first, first.cid > 0 else { throw Problem.empty }
        let reply = try await get(
          "api.bilibili.com", "/x/player/wbi/v2",
          try await signed(["bvid": bv, "cid": String(first.cid)]), P.self)
        return "parts " + String(v.pages.count) + "; guest resume CID "
          + String(reply.last_play_cid ?? 0) + "; guest resume ms "
          + String(reply.last_play_time ?? 0)
      }
      if failures != 0 { exit(1) }
      return
    }
    if let bv = ProcessInfo.processInfo.environment["PILI_SPOKEN_TRACKS"] {
      await check("public spoken track catalog") {
        struct V: Decodable { let cid: Int64 }
        struct P: Decodable {
          let language: SpokenCatalog?, cur_language: String?, dash: DashFormats?
        }
        let detail = try await get(
          "api.bilibili.com", "/x/web-interface/view", ["bvid": bv], V.self)
        let q = try await signed([
          "bvid": bv, "cid": String(detail.cid), "qn": "127", "fnver": "0", "fnval": "4048",
          "fourk": "1",
        ])
        let p = try await get("api.bilibili.com", "/x/player/wbi/playurl", q, P.self)
        guard let dash = p.dash, !dash.video.isEmpty else { throw Problem.empty }
        let tracks = p.language?.ordered ?? []
        let variants = dash.video.compactMap(\.frameRate)
        let sizes = dash.video.filter { $0.width != nil && $0.height != nil }.count
        return "DASH variants " + String(dash.video.count) + "; with resolution " + String(sizes)
          + "; frame rates " + String(describing: Set(variants).sorted()) + "; language rows "
          + String(tracks.count) + "; selected "
          + (p.cur_language ?? "none") + "; AI rows "
          + String(tracks.filter { $0.production_type == 2 }.count)
      }
      if failures != 0 { exit(1) }
      return
    }
    if ProcessInfo.processInfo.environment["PILI_LIVE_SEARCH"] == "1" {
      for kind in LiveSearchScope.allCases {
        await check("live search " + kind.service) {
          let q = try await signed([
            "keyword": "音乐", "search_type": kind.service, "page": "1", "page_size": "20",
            "platform": "pc",
          ])
          let r = try await get(
            "api.bilibili.com", "/x/web-interface/wbi/search/type", q, LiveSearchPayload.self)
          let p = try r.page(scope: kind, number: 1, size: 20)
          guard !p.rows.isEmpty else { throw Problem.empty }
          return String(p.rows.count) + " rows; next " + String(p.next != nil)
        }
      }
      if failures != 0 { exit(1) }
      return
    }
    await check("popular and video detail") {
      let videos = try await get(
        "api.bilibili.com", "/x/web-interface/popular", ["pn": "1", "ps": "20"], VideoList.self
      ).list
      guard let first = videos.first else { throw Problem.empty }
      let detail = try await get(
        "api.bilibili.com", "/x/web-interface/view", ["bvid": first.bvid], Video.self)
      guard detail.bvid == first.bvid, detail.cid != nil, detail.pages?.isEmpty == false else {
        throw Problem.contract("detail did not resolve to the selected video and its parts")
      }
      return
        "\(videos.count) videos, selected BV resolved, \(detail.pages!.count) playable part IDs"
    }
    await check("all-site rankings") {
      let videos = try await get(
        "api.bilibili.com", "/x/web-interface/ranking/v2",
        try await signed(["rid": "0", "type": "all"]),
        VideoList.self
      ).list
      guard !videos.isEmpty else { throw Problem.empty }
      return "\(videos.count) videos decoded"
    }
    await check("series index and episode catalog") {
      let shows = try await get(
        "api.bilibili.com", "/pgc/season/index/result",
        [
          "season_type": "1", "page": "1", "pagesize": "20", "type": "1", "order": "4", "sort": "0",
        ], SeriesList.self
      ).list
      guard let first = shows.first else { throw Problem.empty }
      let info = try await get(
        "api.bilibili.com", "/pgc/view/web/season", ["season_id": String(first.id)], SeasonInfo.self
      )
      guard let episodes = info.episodes, !episodes.isEmpty, episodes.allSatisfy({ $0.id > 0 })
      else { throw Problem.empty }
      return "\(shows.count) shows, \(episodes.count) episode IDs"
    }
    await check("live areas") {
      struct Areas:Decodable {let list:[LiveAreaSection]?}
      let areas = try await get(
        "api.live.bilibili.com", "/xlive/app-interface/v2/index/getAreaList",
        ["platform":"ios","mobi_app":"iphone"], Areas.self).list ?? []
      let children = areas.flatMap { $0.area_list ?? [] }
      guard !areas.isEmpty, !children.isEmpty else { throw Problem.empty }
      return "\(areas.count) areas, \(children.count) subareas"
    }
    await check("short live room identity") {
      let room = try await get(
        "api.live.bilibili.com", "/room/v1/Room/room_init", ["id": "6"], LiveRoomIdentity.self)
      guard room.room_id > 0, room.uid > 0, room.room_id != 6 else {
        throw Problem.contract("Short ID failed to resolve")
      }
      return "canonical room and broadcaster IDs decoded"
    }
    await check("search suggestions with native query parameters") {
      let api = "api.bilibili.com"
      let r = try await get(
        api, "/x/web-interface/suggest",
        try await signed([
          "term": "音乐", "highlight": "0", "spmid": "333.1365", "web_location": "333.1365",
        ]), SearchSuggestionsPayload.self)
      let words = r.result?.tag?.compactMap(\.term) ?? []
      guard !words.isEmpty else { throw Problem.empty }
      return "\(words.count) suggestions decoded"
    }
    await check("anonymous video/audio CDN ranges and media indexes") {
      struct Play: Decodable { let dash: DashFormats? }
      let api = "api.bilibili.com"
      let videos = try await get(
        api, "/x/web-interface/popular", ["pn": "1", "ps": "5"], VideoList.self)
      guard let v = videos.list.first else { throw Problem.empty }
      let detail = try await get(
        api, "/x/web-interface/wbi/view", try await signed(["bvid": v.bvid]), Video.self)
      guard let cid = detail.cid else { throw Problem.empty }
      let play = try await get(
        api, "/x/player/wbi/playurl",
        try await signed([
          "bvid": v.bvid, "cid": String(cid), "qn": "64", "fnver": "0", "fnval": "4048",
          "fourk": "1",
        ]), Play.self)
      guard let f = play.dash, let video = f.video.first, let audio = f.audio?.first else {
        throw Problem.contract("No separate video and audio tracks")
      }
      for stream in [video, audio] {
        guard let url = stream.routes(audio: false).first,
          let span = ByteSpan(stream.SegmentBase.indexRange),
          span.count < 1_048_576
        else { throw Problem.contract("Invalid media index range") }
        let range = "bytes=\(span.lower)-\(span.upper)"
        var r = URLRequest(url: url, timeoutInterval: 12)
        r.setValue(range, forHTTPHeaderField: "Range")
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        r.setValue("https://www.bilibili.com/video/\(v.bvid)/", forHTTPHeaderField: "Referer")
        r.setValue(
          "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148",
          forHTTPHeaderField: "User-Agent")
        let client = RangeTransport()
        defer { client.close() }
        let data = try await client.read(r, limit: Int(span.count))
        guard !(try SegmentIndex.parse(data, beginning: span.lower)).isEmpty else {
          throw Problem.empty
        }
      }
      return "both media indexes fetched by byte range and parsed into nonempty playback segments"
    }
    if failures > 0 { exit(1) }
  }
}
