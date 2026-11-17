import Foundation

/// Each rendition follows its own media sequence. Segments in different renditions are aligned by
/// media timestamps / program date, never by matching a video sequence number to an audio number.
final class LiveHLSFeed: @unchecked Sendable {
  typealias Fetch = @Sendable (LiveHLSPlaylist.Resource, Int) async throws -> LiveHLSFetch.Body
  private typealias Sheet = (url: URL, page: LiveHLSPlaylist)
  let demux: Int32, head: LiveHLSPlaylist.Segment, origin90: Int64?
  private let primedLock = NSLock()
  private var primed: LivePackedAudio?
  private let url: URL, origins: Set<String>, first: LiveHLSPlaylist, fetch: Fetch,
    transport: LiveHLSFetch?
  let audio: LiveHLSFeed?, choices: [LiveAudioTrack], selection: LiveAudioTrack?, dateDelta: Int64
  private init(
    _ sheet: Sheet, head: LiveHLSPlaylist.Segment, origins: Set<String>, fetch: @escaping Fetch,
    transport: LiveHLSFetch? = nil, audio: LiveHLSFeed? = nil, choices: [LiveAudioTrack] = [],
    selection: LiveAudioTrack? = nil, dateDelta: Int64 = .min, packed: LivePackedAudio? = nil
  ) {
    first = sheet.page
    url = sheet.url
    self.head = head
    self.origins = origins
    self.fetch = fetch
    self.transport = transport
    self.audio = audio
    self.choices = choices
    self.selection = selection
    self.dateDelta = dateDelta
    primed = packed
    origin90 = packed?.clock
    demux = packed?.demux ?? (head.initial == nil ? 2 : 1)
  }
  static func open(
    url: URL, room: Int64, codec: String, origins: Set<String>, selected: LiveAudioTrack? = nil, preserveSystemSelection:Bool=false
  ) async throws -> LiveHLSFeed {
    let net = LiveHLSFetch(room: room, origins: origins)
    do {
      return try await prepare(
        url: url, codec: codec, origins: origins, selected: selected, transport: net, preserveSystemSelection:preserveSystemSelection
      ) { r, n in try await net.read(r, limit: n) }
    } catch {
      net.close()
      throw error
    }
  }
  static func prepare(
    url: URL, codec: String, origins: Set<String>, selected: LiveAudioTrack? = nil,
    transport: LiveHLSFetch? = nil, preserveSystemSelection:Bool=false, fetch: @escaping Fetch
  ) async throws -> LiveHLSFeed {
    var here = url
    var seen = Set<URL>()
    var empty = 0
    var alternates: [LiveHLSPlaylist.Audio] = []
    for _ in 0..<6 {
      try Task.checkCancellation()
      let doc = try await fetch(.init(url: here, bytes: nil), 512 * 1024)
      let page = try LiveHLSPlaylist(data: doc.data, base: doc.url, origins: origins)
      if preserveSystemSelection,let text=String(data:doc.data,encoding:.utf8){
        // Keep the original asset when system adaptation, subtitles, camera angles, in-band
        // audio selection, low latency delivery or object metadata would be lost by remuxing.
        if page.variants.count>1 || page.renditions.filter({$0.url==nil}).count>1
          || ["TYPE=SUBTITLES","TYPE=CLOSED-CAPTIONS","TYPE=VIDEO","#EXT-X-PART:","#EXT-X-SERVER-CONTROL:","#EXT-X-DATERANGE:"].contains(where:text.contains){
          throw LivePlaylistError.separateAudio
        }
      }
      if let variant = try page.variant(codec: codec) {
        guard seen.insert(here).inserted, !seen.contains(variant.url) else {
          throw LivePlaylistError.malformed
        }
        if let group = variant.group {
          alternates = page.renditions.filter { $0.group == group }
          guard !alternates.isEmpty else { throw LivePlaylistError.separateAudio }
        }
        here = variant.url
        continue
      }
      guard !page.media.isEmpty else {
        guard !page.finished, empty < 2 else { throw LivePlaylistError.malformed }
        empty += 1
        try await Task.sleep(nanoseconds: UInt64(min(2, page.target / 2) * 1_000_000_000))
        here = doc.url
        continue
      }
      guard let tail = page.media.last,
        let v = page.media.suffix(3).first(where: { $0.epoch == tail.epoch && !$0.gap })
      else { throw LivePlaylistError.discontinuity }
      let choices = alternates.map(\.choice)
      let chosen: LiveHLSPlaylist.Audio?
      if let selected {
        guard let match = LiveAudioTrack.match(selected, in: choices),
          let entry = alternates.first(where: { $0.choice.id == match.id })
        else { throw LivePlaylistError.separateAudio }
        chosen = entry
      } else {
        chosen =
          alternates.first(where: \.preferred) ?? alternates.first(where: \.automatic)
          ?? alternates.first
      }
      var companion: LiveHLSFeed?
      var delta: Int64 = .min
      if let u = chosen?.url {
        let doc = try await fetch(.init(url: u, bytes: nil), 512 * 1024)
        let audio = try LiveHLSPlaylist(data: doc.data, base: doc.url, origins: origins)
        guard audio.variants.isEmpty else { throw LivePlaylistError.separateAudio }
        let same = audio.media.filter { $0.epoch == v.epoch && !$0.gap }
        guard let latest = same.last else { throw LivePlaylistError.discontinuity }
        let a: LiveHLSPlaylist.Segment
        if let at = v.date, same.contains(where: { $0.date != nil }) {
          guard let align = same.last(where: { $0.date.map({ $0 <= at }) ?? false }) ?? same.first
          else { throw LivePlaylistError.discontinuity }
          a = align
          if let ad = a.date {
            let diff = ad.timeIntervalSince(at)
            guard abs(diff) <= max(45, a.seconds * 3) else { throw LivePlaylistError.discontinuity }
            delta = Int64((diff * 1_000_000).rounded())
          }
        } else {
          let span = page.media.filter { $0.id >= v.id }.reduce(0.0) { $0 + $1.seconds }
          var total = 0.0
          var first = latest
          for candidate in same.suffix(32).reversed() {
            first = candidate
            total += candidate.seconds
            if total >= span + min(2, audio.target) { break }
          }
          a = first
        }
        var prepared: LivePackedAudio?
        if a.initial == nil {
          let first = try await fetch(a.media, 32 * 1024 * 1024)
          prepared = try LivePackedAudio.inspect(first.data)
          if let p = prepared, p.demux >= 3, p.clock == nil, delta == Int64.min {
            throw LivePlaylistError.separateAudio
          }
        }
        companion = LiveHLSFeed(
          (doc.url, audio), head: a, origins: origins, fetch: fetch, packed: prepared)
      }
      return LiveHLSFeed(
        (doc.url, page), head: v, origins: origins, fetch: fetch, transport: transport,
        audio: companion, choices: choices, selection: chosen?.choice, dateDelta: delta)
    }
    throw LivePlaylistError.malformed
  }
  func run(send: @Sendable (Data) async throws -> Void) async throws {
    var tab = first
    var next = head.id
    var lastClock: Int64?
    var lastDuration: Double = 0
    let initial = head.initial
    let epoch = head.epoch
    if let initFile = initial {
      let body = try await fetch(initFile, 4 * 1024 * 1024)
      try await send(body.data)
    }
    while true {
      try Task.checkCancellation()
      guard let first = tab.media.first, first.id <= next else {
        throw LivePlaylistError.discontinuity
      }
      for s in tab.media where s.id >= next {
        guard s.id == next, s.epoch == epoch, s.initial == initial, !s.gap else {
          throw LivePlaylistError.discontinuity
        }
        let prepared: LivePackedAudio?
        if s.id == head.id {
          prepared = primedLock.withLock {
            let d = primed
            primed = nil
            return d
          }
        } else {
          prepared = nil
        }
        let bytes: Data
        if let prepared {
          bytes = prepared.bytes
          lastClock = prepared.clock
        } else {
          let current = try await fetch(s.media, 32 * 1024 * 1024)
          if demux >= 3 {
            let p = try LivePackedAudio.inspect(current.data)
            guard p.demux == demux else { throw LivePlaylistError.discontinuity }
            if let c = p.clock, let lastClock {
              let diff = ((c - lastClock) + 8_589_934_592) % 8_589_934_592
              guard abs(Double(diff) / 90000 - lastDuration) < max(0.25, lastDuration * 0.06) else {
                throw LivePlaylistError.discontinuity
              }
            } else if origin90 != nil, p.clock == nil {
              throw LivePlaylistError.discontinuity
            }
            lastClock = p.clock
            bytes = p.bytes
          } else {
            bytes = current.data
          }
        }
        try Task.checkCancellation()
        try await send(bytes)
        next += 1
        lastDuration = s.seconds
      }
      if tab.finished { return }
      try await Task.sleep(nanoseconds: UInt64(min(4, max(0.3, tab.target / 2)) * 1_000_000_000))
      let updated = try await fetch(.init(url: url, bytes: nil), 512 * 1024)
      tab = try LiveHLSPlaylist(data: updated.data, base: updated.url, origins: origins)
      guard tab.variants.isEmpty else { throw LivePlaylistError.discontinuity }
    }
  }
  func close() { transport?.close() }
  deinit { transport?.close() }
}
