import Foundation

struct SubtitleTrack: Decodable, Identifiable {
  let lan: String, name: String, subtitle_url: String, trackID: String, isAI: Bool
  var id: String { trackID.isEmpty ? lan + ":" + name : trackID }
  var lan_doc: String {
    let text = name.isEmpty ? lan : name
    return isAI && !text.hasSuffix("（AI）") ? text + "（AI）" : text
  }
  init(language: String, name: String, url: String, id: String, ai: Bool) {
    lan = language
    self.name = name
    subtitle_url = url
    trackID = id
    isAI = ai || language.lowercased().hasPrefix("ai")
  }
  enum CodingKeys: String, CodingKey { case lan, lan_doc, subtitle_url, id_str, id, type }
  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let lang = try c.decodeIfPresent(String.self, forKey: .lan) ?? ""
    let identifier =
      (try? c.decode(String.self, forKey: .id_str)) ?? (try? c.decode(Int64.self, forKey: .id)).map(
        String.init) ?? ""
    self.init(
      language: lang, name: try c.decodeIfPresent(String.self, forKey: .lan_doc) ?? "",
      url: try c.decodeIfPresent(String.self, forKey: .subtitle_url) ?? "", id: identifier,
      ai: (try? c.decode(Int.self, forKey: .type)) == 1)
  }
  static func ordered(_ list: [Self]) -> [Self] {
    var seen = Set<String>()
    return list.filter {
      !$0.lan.isEmpty && httpsURL($0.subtitle_url) != nil && seen.insert($0.id).inserted
    }.enumerated().sorted {
      let a = $0.element
      let b = $1.element
      if a.lan.contains("zh") != b.lan.contains("zh") { return a.lan.contains("zh") }
      if a.isAI != b.isAI { return !a.isAI }
      return $0.offset < $1.offset
    }.map(\.element)
  }
}
extension BiliAPI {
  func subtitles(_ bvid: String, cid: Int64, aid: Int64? = nil, expectedAccount: String? = nil)
    async throws -> [SubtitleTrack]
  {
    struct Tracks: Decodable { let subtitles: [SubtitleTrack]? }
    struct Reply: Decodable { let subtitle: Tracks? }
    try Task.checkCancellation()
    let web = try await read(
      "/x/player/wbi/v2", try await sign(["bvid": bvid, "cid": "\(cid)"]),
      expectedAccount: expectedAccount, as: Reply.self
    )
    let rows = SubtitleTrack.ordered(web.subtitle?.subtitles ?? [])
    guard rows.isEmpty, try await AccountJar.shared.current() == nil,
      let archive = aid ?? ArchiveNumber.av(bvid)
    else { return rows }
    try Task.checkCancellation()
    return SubtitleTrack.ordered(
      try await guestSubtitleTracks(aid: archive, cid: cid).map {
        SubtitleTrack(language: $0.language, name: $0.name, url: $0.url, id: $0.id, ai: $0.ai)
      })
  }
  func cues(_ t: SubtitleTrack) async throws -> [SubtitleCue] {
    try await subtitleDocument(t).cues
  }
  func subtitleDocument(_ t: SubtitleTrack) async throws -> SubtitleDocument {
    guard let url = httpsURL(t.subtitle_url), url.scheme == "https", url.user == nil,
      url.password == nil
    else { throw ServiceError("字幕地址无效") }
    var req = URLRequest(url: url, timeoutInterval: 20)
    req.httpShouldHandleCookies = false
    req.setValue("https://www.bilibili.com/", forHTTPHeaderField: "Referer")
    let (bytes, response) = try await URLSession.shared.bytes(for: req, delegate: CertificateSessionDelegate())
    guard response.url?.scheme == "https", (response as? HTTPURLResponse)?.statusCode == 200,
      response.expectedContentLength <= Int64(SubtitleDocument.maxBytes)
    else { throw ServiceError("无法读取字幕") }
    var packet = Data()
    packet.reserveCapacity(
      min(SubtitleDocument.maxBytes, max(4096, Int(response.expectedContentLength))))
    for try await b in bytes {
      guard packet.count < SubtitleDocument.maxBytes else { throw ServiceError("字幕文件超过 8 MB") }
      packet.append(b)
    }
    try Task.checkCancellation()
    return try SubtitleDocument(packet, format: .json)
  }
}
extension Array where Element == SubtitleCue {
  func active(at t: Double) -> String? {
    var l = 0
    var r = count
    while l < r {
      let m = (l + r) / 2
      if self[m].from <= t { l = m + 1 } else { r = m }
    }
    guard l > 0, self[l - 1].to > t else { return nil }
    return self[l - 1].content
  }
}
