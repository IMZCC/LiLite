import Foundation
import Network

extension BiliAPI {
  func formats(_ bvid: String, cid: Int64, language: String? = nil, expectedAccount: String? = nil, forCache: Bool = false)
    async throws -> DashFormats
  {
    struct Play: Decodable {
      let dash: DashFormats?, language: SpokenCatalog?, cur_language: String?,
        volume: AudioMeasurements?
    }
    var f = [
      "bvid": bvid, "cid": String(cid), "qn": "129", "fnver": "0", "fnval": "4048", "fourk": "1",
    ]
    f["voice_balance"] = AudioFilterChoice.requestsProcessing ? "1" : "0"
    f["cur_language"] = language
    let owner = try await AccountJar.shared.current(.role(.video))?.id ?? ""
    if let expectedAccount, expectedAccount != owner { throw ServiceError("视频账号已切换") }
    f.merge(ArchiveStreamGrant.requestFields(guest: owner.isEmpty)) { current, _ in current }
    func request(_ quality: Int) async throws -> ArchiveGrantResponse<Play> {
      var fields = f; fields["qn"] = String(quality)
      return try await read("/x/player/wbi/playurl", try await sign(fields), expectedAccount: owner, as: ArchiveGrantResponse<Play>.self)
    }
    let packet = try await request(129)
    guard !packet.grant.protected, !forCache || packet.grant.permitsCache else { throw ServiceError("此媒体无法用于该播放方式") }
    let p = packet.body
    guard let d = p.dash else { throw ServiceError("这个视频没有分轨播放地址") }
    var result = d.filteringVideo { packet.grant.permits($0, guest: owner.isEmpty) }.withLanguages(p.language, p.cur_language, volume: p.volume)
    result.isPreview = packet.grant.preview
    if let missing = result.missingBelowHighest(packet.grant.advertisedQualities.filter { packet.grant.permits($0, guest: owner.isEmpty) }) {
      do {
        let supplemental = try await request(missing)
        guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == owner else { throw ServiceError("视频账号已切换") }
        if !supplemental.grant.protected, !forCache || supplemental.grant.permitsCache,
          supplemental.grant.preview == result.isPreview, supplemental.body.cur_language == p.cur_language,
          let added = supplemental.body.dash {
          result = result.mergingVideo(added.filteringVideo { supplemental.grant.permits($0, guest: owner.isEmpty) })
        }
      } catch { try Task.checkCancellation() }
    }
    guard (try await AccountJar.shared.current(.role(.video))?.id ?? "") == owner else { throw ServiceError("视频账号已切换") }
    if !forCache {
      result = await HighQualityPlayback.applyUGCN(result, fields: f, owner: owner)
    }
    return result
  }
}
struct HLSVariant { let quality: Int, title: String }
enum StreamQuality {
  static func name(_ q: Int) -> String {
    [
      129: "HDR Vivid", 100: "智能修复", 127: "8K", 126: "杜比视界", 125: "HDR", 120: "4K", 116: "1080P60",
      112: "1080P 高码率", 80: "1080P",
      74: "720P60", 64: "720P", 32: "480P", 16: "360P", 6: "240P",
    ][q] ?? "\(q)"
  }
}
private struct TrackIndex {
  let stream: DashStream
  let audio: Bool
  let initial: ByteSpan
  let fragments: [IndexedSegment]
  var earliest: Double = 0
  func playlist(converting: Bool) -> Data {
    var lines = [
      "#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-PLAYLIST-TYPE:VOD",
      "#EXT-X-TARGETDURATION:\(Int(ceil(fragments.map(\.seconds).max() ?? 1)))",
      "#EXT-X-MEDIA-SEQUENCE:0",
    ]
    if !converting { lines.append("#EXT-X-MAP:URI=\"init.mp4\"") }
    for (i, s) in fragments.enumerated() {
      if converting { lines.append("#EXT-X-MAP:URI=\"init-\(i).mp4\"") }
      lines += ["#EXTINF:\(s.seconds),", "\(i).m4s"]
    }
    lines += ["#EXT-X-ENDLIST", ""]
    return Data(lines.joined(separator: "\n").utf8)
  }
}
final class DashBridge: PictureTimingSource, @unchecked Sendable {
  private let token = UUID().uuidString
  private let queue = DispatchQueue(label: "pilinative.dash")
  private var waitingForPort = true  // accessed only on the listener queue
  private var listener: NWListener?
  private let transport: RangeTransport?, buffer = MediaBufferSession()
  private let expectedOwner: String?, expectedRole: AccountRole
  private let local: OfflineDecoderSource?
  private var jobs: [ObjectIdentifier: Task<Void, Never>] = [:]
  private var demands: [ObjectIdentifier: (String, Int)] = [:]
  private let modes: [NativeVideoRoute]?
  private let decoder = DecoderSegments(), audioDecoder = DecoderSegments()
  private var audioFilter = "", filteredAudioRate: Int?
  private let decodePressure: MediaBufferPressure
  private let fallbackLock = NSLock()
  private var alternatives: [NativeVideoRoute] = []
  private var encoding: DecoderFragment.Encoding?
  private(set) var decodeRoute: NativeVideoRoute = .direct
  private let ref: URL?
  private var tracks: [String: TrackIndex] = [:]
  private var clockEnds: [Double] = []
  private var clockOrigin = 0.0
  private var connections: [ObjectIdentifier: NWConnection] = [:]
  convenience init(reference: URL, decoding: [NativeVideoRoute]? = nil, expectedOwner: String? = nil, expectedRole: AccountRole = .video) {
    self.init(reference: reference, local: nil, decoding: decoding, expectedOwner: expectedOwner, expectedRole: expectedRole)
  }
  convenience init(local: OfflineDecoderSource, decoding: [NativeVideoRoute]? = nil) {
    self.init(reference: nil, local: local, decoding: decoding)
  }
  private func authorize() async throws {
    if let local { try await local.authorize() }
    if let expectedOwner, (try await AccountJar.shared.current(.role(expectedRole))?.id ?? "") != expectedOwner {
      throw ServiceError("播放账号已切换")
    }
  }
  private init(reference: URL?, local: OfflineDecoderSource?, decoding: [NativeVideoRoute]?, expectedOwner: String? = nil, expectedRole: AccountRole = .video) {
    self.expectedOwner = expectedOwner
    self.expectedRole = expectedRole
    self.local = local
    transport = local == nil ? RangeTransport() : nil
    ref = reference
    modes = decoding
    let pool = decoder
    let audioPool = audioDecoder
    decodePressure = MediaBufferPressure {
      Task {
        await pool.trim()
        await audioPool.trim()
      }
    }
  }
  var remainingDecoderRoutes: [NativeVideoRoute] { fallbackLock.withLock { alternatives } }
  func takeRemainingDecoderRoutes() -> [NativeVideoRoute] {
    fallbackLock.withLock {
      let rest = alternatives
      alternatives = []
      return rest
    }
  }
  private func converted(_ index: Int, track: TrackIndex, mode: NativeVideoRoute) async throws
    -> DecoderFragment
  {
    try await decoder.load(index) {
      try Task.checkCancellation()
      guard track.initial.lower == 0, track.initial.count <= 4 * 1024 * 1024,
        track.fragments.indices.contains(index)
      else { throw DecoderProblem.size }
      let initial = try await self.bytes(track.stream, track.initial, audio: false)
      let wanted = track.fragments[index].bytes
      for n in stride(from: index, through: max(0, index - 4), by: -1) {
        let begin = track.fragments[n].bytes.lower
        guard begin >= 0, wanted.upper >= begin, wanted.upper - begin < 48 * 1024 * 1024 else {
          throw DecoderProblem.size
        }
        let bytes = try await self.bytes(
          track.stream, ByteSpan(begin, wanted.upper), audio: false,
          end: track.fragments.last?.bytes.upper)
        do {
          return try await DecoderSegment.convert(
            initial: initial, media: bytes, source: begin, target: wanted.lower, index: index,
            route: mode)
        } catch DecoderProblem.keyframe { if n == 0 { throw DecoderProblem.keyframe } }
      }
      throw DecoderProblem.keyframe
    }
  }
  // Both AVKit's local rendition and the independent device audio clock read the same granted
  // track, init data and bounded preroll. For an active sound effect reuse its cached output.
  var clockFPS: Double? { tracks["v"]?.stream.frameRate }
  func clockIndex(at time:Double)->Int? {
    guard time.isFinite,time>=0,!clockEnds.isEmpty,time < clockEnds.last! else {return nil}
    var lo=0,hi=clockEnds.count
    while lo<hi {let m=lo+(hi-lo)/2;if clockEnds[m]<=time {lo=m+1}else{hi=m}}
    return lo
  }
  func clockPart(_ n:Int) async throws -> ClockAudioPart? {
    try await authorize()
    guard let track=tracks["a"],track.fragments.indices.contains(n),AudioSegment.supports(track.stream.codecs) else{return nil}
    let raw:ClockPCM
    if !audioFilter.isEmpty{
      let active=try await processedAudio(n,track:track)
      let offset=Int64(active.initial.count)
      raw=try await ClockPCM.decode(initial:active.initial,media:active.media,offset:offset,target:.init(offset,offset+Int64(active.media.count)-1))
    }else{
      let (prefix,media,span,target)=try await audioWindow(n,track:track)
      raw=try await ClockPCM.decode(initial:prefix,media:media,offset:span.lower,target:target)
    }
    try await authorize();try Task.checkCancellation()
    let start=Double(raw.startSample)/Double(raw.rate)-clockOrigin
    // A discontinuity outside this playlist's advertised time base must retain the native renderer.
    guard start.isFinite,abs(start-(clockEnds[n]-track.fragments[n].seconds))<0.5 else{throw DecoderProblem.unsupported}
    return .init(index:n,start:start,pcm:raw)
  }
  private func audioWindow(_ n:Int,track:TrackIndex) async throws -> (Data,Data,ByteSpan,ByteSpan) {
      let target = track.fragments[n].bytes
      // AAC overlap and optional filter look-ahead must be available even after a non-linear seek.
      let window = self.audioFilter.contains("norm=") ? 7.0 : 0.08
      var a = n
      var b = n
      var time = 0.0
      while a > 0, time < window, n - a < 12,
        target.upper - track.fragments[a - 1].bytes.lower < 32 * 1024 * 1024
      {
        a -= 1
        time += track.fragments[a].seconds
      }
      time = 0
      while b + 1 < track.fragments.count, time < window, b - n < 12,
        track.fragments[b + 1].bytes.upper - track.fragments[a].bytes.lower < 48 * 1024 * 1024
      {
        b += 1
        time += track.fragments[b].seconds
      }
      let span = ByteSpan(track.fragments[a].bytes.lower, track.fragments[b].bytes.upper)
      guard span.count <= 48 * 1024 * 1024 else { throw DecoderProblem.size }
      let prefix = try await self.bytes(track.stream, track.initial, audio: true)
      let media = try await self.bytes(
        track.stream, span, audio: true, end: track.fragments.last?.bytes.upper)
      return (prefix,media,span,target)
  }
  private func processedAudio(_ n: Int, track: TrackIndex) async throws -> DecoderFragment {
    try await audioDecoder.load(n) {
      let (prefix,media,span,target)=try await self.audioWindow(n,track:track)
      return try await AudioSegment.convert(
        initial: prefix, media: media, offset: span.lower, target: target, index: n,
        filter: self.audioFilter)
    }
  }
  private func bytes(_ stream: DashStream, _ span: ByteSpan, audio: Bool, end: Int64? = nil)
    async throws -> Data
  {
    let seconds = UserDefaults.standard.object(forKey: "play.bufferSeconds") as? Double ?? 16
    let horizon = MediaBufferPolicy.horizon(
      after: span.upper, end: end, bitsPerSecond: stream.bandwidth, seconds: seconds)
    return try await buffer.window.read(
      lane: audio ? 1 : 0, from: span.lower, through: span.upper, endOfMedia: horizon
    ) { a, b in
      try await self.fetch(stream, ByteSpan(a, b), audio: audio)
    }
  }
  private func fetch(_ stream: DashStream, _ span: ByteSpan, audio: Bool) async throws -> Data {
    if let local { return try await local.read(span, audio: audio) }
    guard let ref, let transport else { throw URLError(.unsupportedURL) }
    var last: Error = URLError(.cannotConnectToHost)
    for url in stream.routes(audio: audio) {
      try Task.checkCancellation()
      try await authorize()
      do {
        func read(as identity: MediaClientIdentity) async throws -> Data {
          var r = URLRequest(url: url)
          // Web addresses keep the request they always made (Referer, the session's own agent).
          if identity == .appPlayer { identity.apply(to: &r, reference: ref) }
          else { r.setValue(ref.absoluteString, forHTTPHeaderField: "Referer") }
          r.setValue("bytes=\(span.lower)-\(span.upper)", forHTTPHeaderField: "Range")
          r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
          return try await transport.read(r, limit: Int(span.count))
        }
        // App-issued addresses (the listener's audio) want the app player; a 403 tries the other.
        let identity = MediaClientIdentity.expected(for: url)
        let bytes: Data
        do { bytes = try await read(as: identity) }
        catch let error where MediaClientIdentity.refused(error) { bytes = try await read(as: identity.other) }
        try await authorize()
        return bytes
      } catch { last = error }
    }
    throw last
  }
  private func index(_ stream: DashStream, audio: Bool) async throws -> TrackIndex {
    if let local {
      guard let source = audio ? local.audio : local.video else { throw LocalIndexIssue.invalid }
      return .init(
        stream: stream, audio: audio, initial: source.initial, fragments: source.fragments)
    }
    guard let initRange = ByteSpan(stream.SegmentBase.Initialization),
      let indexes = ByteSpan(stream.SegmentBase.indexRange)
    else { throw SegmentIndex.Invalid.malformed }
    let t = try await SegmentIndex.timeline(bytes(stream, indexes, audio: audio), beginning: indexes.lower)
    return .init(stream: stream, audio: audio, initial: initRange, fragments: t.segments, earliest: t.start)
  }
  var isProgressive: Bool { local?.remote != nil }
  func legacyRendition(audio: Bool, url: URL) -> LegacyDURLPlaylist.Rendition? {
    let lane = audio ? "a" : "v"
    guard let t = tracks[lane], !t.fragments.isEmpty else { return nil }
    let base = url.lastPathComponent == "master.m3u8" ? url.deletingLastPathComponent() : url.deletingLastPathComponent().deletingLastPathComponent()
    return .init(
      base: base.appendingPathComponent(lane + "/index.m3u8"),
      playlist: t.playlist(converting: audio ? !audioFilter.isEmpty : decodeRoute.converts),
      duration: t.fragments.reduce(0) { $0 + $1.seconds },
      bandwidth: audio ? (filteredAudioRate ?? t.stream.bandwidth) : t.stream.bandwidth)
  }
  func legacyPiece(audio: Bool, initial: Bool) async throws -> Data {
    try await authorize()
    guard let track = tracks[audio ? "a" : "v"], !track.fragments.isEmpty else { throw LocalIndexIssue.invalid }
    let converting = audio ? !audioFilter.isEmpty : decodeRoute.converts
    if initial {
      if converting { return try await (audio ? processedAudio(0, track: track) : converted(0, track: track, mode: decodeRoute)).initial }
      return try await bytes(track.stream, track.initial, audio: audio)
    }
    var result = Data()
    for (n, fragment) in track.fragments.enumerated() {
      let bytes: Data
      if converting { bytes = try await (audio ? processedAudio(n, track: track) : converted(n, track: track, mode: decodeRoute)).media }
      else { bytes = try await self.bytes(track.stream, fragment.bytes, audio: audio) }
      guard result.count <= 48 * 1024 * 1024 - bytes.count else { throw DecoderProblem.size }
      result.append(bytes)
    }
    return result
  }
  func cancelDemands() {
    queue.async {
      self.jobs.values.forEach { $0.cancel() }
      self.jobs.removeAll()
      self.demands.removeAll()
      self.connections.values.forEach { $0.cancel() }
    }
  }
  func reopenProgressive(routes: [NativeVideoRoute]) async throws -> (bridge: DashBridge, url: URL)
  {
    guard let local, local.remote != nil else { throw LocalIndexIssue.invalid }
    return try await ProgressiveDecoderBridge.start(local, routes: routes)
  }
  func startLocal() async throws -> URL {
    guard let local else { throw LocalIndexIssue.invalid }
    try await local.authorize()
    return try await start(video: local.videoStream, audio: local.audioStream, volume: local.volume)
  }
  func start(video: DashStream, audio: DashStream?, volume: AudioMeasurements? = nil) async throws
    -> URL
  {
    try Task.checkCancellation()
    async let videoIndex = index(video, audio: false)
    if let audio{try await prepareAudio(audio,volume:volume)}
    let videoTrack = try await videoIndex
    tracks["v"] = videoTrack
    let available = DecoderOptions.routes(video)
    let candidates = (modes ?? available).filter { available.contains($0) }
    guard !candidates.isEmpty else { throw DecoderProblem.unsupported }
    var selected = false
    for (i, mode) in candidates.enumerated() {
      try Task.checkCancellation()
      if mode.converts {
        do { encoding = try await converted(0, track: videoTrack, mode: mode).encoding } catch let e
          as DecoderProblem
        {
          await decoder.reset()
          if i == candidates.count - 1 { throw e }
          continue
        }
      }
      decodeRoute = mode
      fallbackLock.withLock { alternatives = Array(candidates.dropFirst(i + 1)) }
      selected = true
      break
    }
    guard selected else { throw DecoderProblem.unsupported }
    if let a=tracks["a"] {
      clockOrigin=min(a.earliest,videoTrack.earliest)
      var time=a.earliest-clockOrigin
      clockEnds=a.fragments.map { time += $0.seconds; return time }
    }
    let url=try await openListener(playlist:"master.m3u8")
    if let audio,AudioSegment.supports(audio.codecs){PictureTimingRegistry.shared.add(url,source:self)}
    return url
  }
  private func prepareAudio(_ audio:DashStream,volume:AudioMeasurements?)async throws{
    let a=try await index(audio,audio:true)
    guard !a.fragments.isEmpty else{throw SegmentIndex.Invalid.malformed}
    tracks["a"]=a
    audioFilter=AudioSegment.supports(audio.codecs) ? AudioFilterChoice.current(volume):""
    if !audioFilter.isEmpty{
      let fragment=try await processedAudio(0,track:a)
      filteredAudioRate=Int(min(50_000_000,max(Double(audio.bandwidth),Double(fragment.media.count)*8*1.4/max(0.001,a.fragments[0].seconds))))
    }
  }
  func startAudio(_ audio:DashStream,volume:AudioMeasurements?)async throws->URL{
    try Task.checkCancellation();try await authorize()
    try await prepareAudio(audio,volume:volume)
    if let a = tracks["a"] {
      clockOrigin = a.earliest
      var time = 0.0
      clockEnds = a.fragments.map { time += $0.seconds; return time }
    }
    return try await openListener(playlist:"a/index.m3u8")
  }
  private func openListener(playlist:String)async throws->URL{
    try Task.checkCancellation()
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let l = try NWListener(using: params)
    listener = l
    let port: UInt16 = try await withCheckedThrowingContinuation { cont in
      l.stateUpdateHandler = { state in
        guard self.waitingForPort else { return }
        switch state {
        case .ready:
          self.waitingForPort = false
          if let p = l.port {
            cont.resume(returning: p.rawValue)
          } else {
            cont.resume(throwing: URLError(.cannotConnectToHost))
          }
        case .failed(let e):
          self.waitingForPort = false
          cont.resume(throwing: e)
        case .cancelled:
          self.waitingForPort = false
          cont.resume(throwing: CancellationError())
        default: break
        }
      }
      l.newConnectionHandler = { [weak self] conn in
        guard let self else {
          conn.cancel()
          return
        }
        self.connections[ObjectIdentifier(conn)] = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
          guard let conn else { return }
          switch state {
          case .cancelled, .failed:
            let key = ObjectIdentifier(conn)
            self?.jobs.removeValue(forKey: key)?.cancel()
            self?.demands.removeValue(forKey: key)
            self?.connections.removeValue(forKey: key)
          default: break
          }
        }
        conn.start(queue: self.queue)
        self.receive(conn, Data())
      }
      l.start(queue: queue)
    }
    return URL(string: "http://127.0.0.1:\(port)/\(token)/\(playlist)")!
  }
  /// Cancel old fragment transfers that are far from an explicit seek. Cached bytes remain valid.
  func seek(to seconds: Double) {
    guard seconds.isFinite, seconds >= 0 else { return }
    queue.async {
      for (lane, track) in self.tracks {
        var t = 0.0
        let target =
          track.fragments.firstIndex { f in
            t += f.seconds
            return t > seconds
          } ?? max(0, track.fragments.count - 1)
        if lane == "v" && self.decodeRoute.converts { Task { await self.decoder.seek(target) } }
        if lane == "a" && !self.audioFilter.isEmpty {
          Task { await self.audioDecoder.seek(target) }
        }
        let obsolete = self.demands.filter { $0.value.0 == lane && abs($0.value.1 - target) > 2 }
          .map(\.key)
        for key in obsolete {
          self.jobs.removeValue(forKey: key)?.cancel()
          self.connections[key]?.cancel()
          self.demands[key] = nil
        }
      }
    }
  }
  func close() {
    Task {
      await decoder.stop()
      await audioDecoder.stop()
    }
    buffer.close()
    transport?.close()
    queue.async {
      self.listener?.cancel()
      self.listener = nil
      for c in self.connections.values { c.cancel() }
      self.connections.removeAll()
      self.jobs.values.forEach { $0.cancel() }
      self.jobs.removeAll()
      self.demands.removeAll()
    }
  }
  private func receive(_ c: NWConnection, _ buffer: Data) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] d, _, done, err in
      guard let self, let d, !d.isEmpty, err == nil else {
        c.cancel()
        return
      }
      var accumulated = buffer
      accumulated.append(d)
      guard accumulated.count <= 16384 else {
        c.cancel()
        return
      }
      guard let text = String(data: accumulated, encoding: .utf8), text.contains("\r\n\r\n") else {
        if done { c.cancel() } else { self.receive(c, accumulated) }
        return
      }
      let key = ObjectIdentifier(c)
      let path = text.components(separatedBy: "\r\n").first?.split(separator: " ").dropFirst()
        .first?.split(separator: "/")
      if let parts = path, parts.count == 3, parts[0] == self.token[...],
        let part = DecoderFragment.request(String(parts[2])),
        let track = self.tracks[String(parts[1])],
        track.fragments.indices.contains(part.index)
      {
        self.demands[key] = (String(parts[1]), part.index)
      }
      self.jobs[key] = Task {
        await self.serve(c, text)
        self.queue.async {
          self.jobs[key] = nil
          self.demands[key] = nil
        }
      }
    }
  }
  private func serve(_ c: NWConnection, _ request: String) async {
    let lines = request.components(separatedBy: "\r\n")
    let fields = (lines.first ?? "").split(separator: " ")
    guard fields.count == 3, fields[0] == "GET" || fields[0] == "HEAD" else {
      reply(c, 405)
      return
    }
    let path = fields[1].split(separator: "/").map(String.init)
    guard path.first == token else {
      reply(c, 404)
      return
    }
    do { try await authorize() } catch { reply(c, 403); return }
    let head = fields[0] == "HEAD"
    if path.count == 2 && path[1] == "master.m3u8", let video = tracks["v"] {
      let audio = tracks["a"]
      var m = "#EXTM3U\n#EXT-X-VERSION:7\n"
      if audio != nil {
        m +=
          "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"原声\",DEFAULT=YES,AUTOSELECT=YES,URI=\"a/index.m3u8\"\n"
      }
      let attrs: String
      if decodeRoute.converts {
        // The local encoder now supplies video; do not advertise the original AV1/HEVC codec.
        let w = min(8192, max(1, video.stream.width ?? 1920))
        let h = min(4608, max(1, video.stream.height ?? 1080))
        let videoRate = max(450000, min(35_000_000, w * h * 6))
        var fields = [
          "BANDWIDTH="
            + String(
              videoRate + min(12_000_000, max(0, filteredAudioRate ?? audio?.stream.bandwidth ?? 0))
            )
        ]
        if let encoding {
          if let codec = encoding.codec {
            var all = [codec]
            if let a = (audioFilter.isEmpty ? audio?.stream.codecs : "alac"), !a.isEmpty,
              a.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0)
                  || $0 == 46 || $0 == 45
              })
            {
              all.append(a)
            }
            fields.append("CODECS=\"" + all.joined(separator: ",") + "\"")
          }
          if encoding.width > 0 && encoding.height > 0 {
            fields.append("RESOLUTION=\(encoding.width)x\(encoding.height)")
          }
          fields.append("VIDEO-RANGE=" + encoding.range)
        }
        if audio != nil { fields.append("AUDIO=\"audio\"") }
        attrs = fields.joined(separator: ",")
      } else {
        attrs = video.stream.masterAttributes(
          audio: audio?.stream, audioCodec: audioFilter.isEmpty ? nil : "alac",
          audioRate: filteredAudioRate)
      }
      m += "#EXT-X-STREAM-INF:" + attrs + "\nv/index.m3u8\n"
      reply(c, 200, Data(m.utf8), type: "application/vnd.apple.mpegurl", head: head)
      return
    }
    guard path.count == 3, let track = tracks[path[1]] else {
      reply(c, 404)
      return
    }
    if path[2] == "index.m3u8" {
      reply(
        c, 200,
        track.playlist(converting: track.audio ? !audioFilter.isEmpty : decodeRoute.converts),
        type: "application/vnd.apple.mpegurl", head: head)
      return
    }
    if track.audio ? !audioFilter.isEmpty : decodeRoute.converts {
      guard let part = DecoderFragment.request(path[2]),
        track.fragments.indices.contains(part.index)
      else {
        reply(c, 404)
        return
      }
      let n = part.index
      let initFile = part.initial
      do {
        let fragment =
          try await track.audio
          ? processedAudio(n, track: track) : converted(n, track: track, mode: decodeRoute)
        let segment = initFile ? fragment.initial : fragment.media
        try Task.checkCancellation()
        let count = Int64(segment.count)
        if let line = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
          let raw = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces).lowercased()
          guard let r = RelayRange(raw, length: count) else {
            reply(c, 416, extra: "Content-Range: bytes */\(count)\r\n")
            return
          }
          let part = head ? Data() : segment.subdata(in: Int(r.first)..<Int(r.last + 1))
          reply(
            c, 206, part, type: track.audio ? "audio/mp4" : "video/mp4", head: head,
            length: r.last - r.first + 1,
            extra: "Content-Range: bytes \(r.first)-\(r.last)/\(count)\r\n")
        } else {
          reply(
            c, 200, head ? Data() : segment, type: track.audio ? "audio/mp4" : "video/mp4",
            head: head, length: count)
        }
      } catch { if !Task.isCancelled { reply(c, 502) } }
      return
    }
    let span: ByteSpan
    if path[2] == "init.mp4" {
      span = track.initial
    } else if path[2].hasSuffix(".m4s"), let i = Int(path[2].dropLast(4)),
      track.fragments.indices.contains(i)
    {
      span = track.fragments[i].bytes
    } else {
      reply(c, 404)
      return
    }
    var from: Int64 = 0
    var end = span.count - 1
    var hdr = ""
    if let range = lines.first(where: { $0.lowercased().hasPrefix("range:") }) {
      let v =
        range.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces)
        .lowercased() ?? ""
      guard let range = RelayRange(v, length: span.count) else {
        reply(c, 416, extra: "Content-Range: bytes */\(span.count)\r\n")
        return
      }
      from = range.first
      end = range.last
      hdr = "Content-Range: bytes \(from)-\(end)/\(span.count)\r\n"
    }
    do {
      let body =
        head
        ? Data()
        : try await bytes(
          track.stream, ByteSpan(span.lower + from, span.lower + end), audio: track.audio,
          end: path[2] == "init.mp4" ? nil : track.fragments.last?.bytes.upper)
      reply(
        c, hdr.isEmpty ? 200 : 206, body, type: path[1] == "a" ? "audio/mp4" : "video/mp4",
        head: head, length: end - from + 1, extra: hdr)
    } catch { reply(c, 502) }
  }
  private func reply(
    _ c: NWConnection, _ code: Int, _ content: Data = Data(), type: String = "text/plain",
    head: Bool = false, length: Int64? = nil, extra: String = ""
  ) {
    let phrase =
      [
        200: "OK", 206: "Partial Content", 403: "Forbidden", 404: "Not Found",
        405: "Method Not Allowed",
        416: "Range Not Satisfiable", 502: "Bad Gateway",
      ][code] ?? "Error"
    var d = Data(
      "HTTP/1.1 \(code) \(phrase)\r\nContent-Type: \(type)\r\nContent-Length: \(length ?? Int64(content.count))\r\nAccept-Ranges: bytes\r\n\(extra)Connection: close\r\n\r\n"
        .utf8)
    if !head { d.append(content) }
    c.send(content: d, completion: .contentProcessed { _ in c.cancel() })
  }
}
