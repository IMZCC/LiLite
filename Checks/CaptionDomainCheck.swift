import Foundation

protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
struct SubtitleTrack { let id: String, lan: String, lan_doc: String, isAI: Bool }
enum OfflineExtras {
  struct Language {
    let id: String, name: String, cues: [SubtitleCue], language: String?, ai: Bool?
  }
}
actor BiliAPI {
  static let shared = BiliAPI()
  var delay: CheckedContinuation<Void, Never>?, started = false
  func subtitleDocument(_ row: SubtitleTrack) async throws -> SubtitleDocument {
    if row.id == "slow" {
      started = true
      await withCheckedContinuation { delay = $0 }
    }
    return try SubtitleDocument(cues: [.init(from: 0, to: 4, content: row.lan_doc)])
  }
  func release() {
    delay?.resume()
    delay = nil
  }
}
@main enum CaptionDomainCheck {
  static func data(_ s: String) -> Data { Data(s.utf8) }
  @MainActor static func main() async throws {
    let json = data(
      #"{"source":"保留服务字段","body":[{"from":1.25,"to":2.9996,"location":2,"content":"第一行\n第二行 <3 & 同步"}]}"#
    )
    let j = try SubtitleDocument(json, format: .bcc)
    let raw = try j.bytes(.json)
    precondition(raw == json)
    let vtt = try j.bytes(.vtt)
    let srt = try j.bytes(.srt)
    let vv = try SubtitleDocument(vtt, format: .vtt)
    let ss = try SubtitleDocument(srt, format: .srt)
    precondition(
      vv.cues == ss.cues && vv.cues[0].to == 3 && vv.cues[0].content == j.cues[0].content
        && String(decoding: srt, as: UTF8.self).contains("00:00:03,000"))
    let v = try SubtitleDocument(
      data(
        "WEBVTT\n\nNOTE annotation\n00:01.000 --> 00:02.000\nskip\n\none\n00:01.000 --> 00:03.000 align:center\n<v A><b>hello &lt;3</b>\nsecond\n\n"
      ), format: .vtt)
    precondition(v.cues.count == 1 && v.cues[0].content == "hello <3\nsecond")
    let nonlatin =
      Data([0xff, 0xfe])
      + ("1\r\n00:00:00,400 --> 00:00:01,050\r\n你好".data(using: .utf16LittleEndian)!)
    let utf = try SubtitleDocument(nonlatin, format: .srt)
    precondition(utf.cues[0].from == 0.4 && utf.cues[0].content == "你好")
    let ass = try SubtitleDocument(
      data(
        "[Events]\nFormat: Start, End, Text\nDialogue: 0:00:01.52,0:00:03.04,{\\i1}hello,world\\Nsecond\nDialogue: 0:00:02.00,0:00:05.00,{\\p1}m 0 0 l 4 12{\\p0}\n"
      ), format: .ass)
    precondition(
      ass.cues.count == 1 && ass.cues[0].content == "hello,world\nsecond" && ass.assPayload != nil)
    for (bad, f): (String, SubtitleFileFormat) in [
      ("WEBVTT\n\n00:07.000 --> 00:05.000\nx", .vtt), ("z", .srt),
      ("{\"body\":[{\"from\":-1,\"to\":5,\"content\":\"x\"}]}", .json),
    ] {
      do {
        _ = try SubtitleDocument(data(bad), format: f)
        preconditionFailure()
      } catch {}
    }
    let a = [
      SubtitleCue(from: 0, to: 10, content: "中文"), SubtitleCue(from: 2, to: 3, content: "临时"),
    ]
    let b = [
      SubtitleCue(from: 1, to: 8, content: "English"), SubtitleCue(from: 2, to: 3, content: "中文"),
    ]
    let index = SubtitleTimeline(a, b)
    precondition(
      index.active(at: 2.5) == "中文\n临时\nEnglish" && index.active(at: 3) == "中文\nEnglish"
        && index.active(at: 9) == "中文" && index.active(at: 10) == nil && index.active(at: 0) == "中文"
    )
    var dense = [SubtitleCue]()
    for i in 0..<5000 { dense.append(.init(from: 0, to: Double(i + 1), content: String(i))) }
    let packed = SubtitleTimeline(dense)
    precondition(
      packed.active(at: 4900)?.components(separatedBy: "\n").first == "4900"
        && packed.active(at: 4999) == "4999")
    let background = try await SubtitleTimeline.prepare(dense)
    precondition(background.active(at: 4900) == packed.active(at: 4900))
    precondition(index.interval(at: 2.5) != index.interval(at: 3))
    precondition(index.interval(at: 3) == index.interval(at: 3.99) && index.interval(at: 10) == nil)
    let session = SubtitleSession()
    await session.offer([
      .init(id: "ok", lan: "en", lan_doc: "English", isAI: false),
      .init(id: "slow", lan: "zh", lan_doc: "迟到", isAI: false),
    ])
    try await session.add(j, name: "本地字幕", bytes: json.count)
    let local = session.first
    await session.select("ok", secondary: true)
    precondition(session.timeline.active(at: 1.5) == j.cues[0].content + "\nEnglish")
    await session.select(local, secondary: true)
    precondition(session.second == nil)
    let pending = Task { await session.select("slow") }
    while !(await BiliAPI.shared.started) { await Task.yield() }
    session.reset()
    await BiliAPI.shared.release()
    await pending.value
    precondition(
      session.tracks.isEmpty && session.timeline.active(at: 2) == nil && session.first == nil)
    print(
      "Caption: BCC/JSON raw preservation, VTT/SRT milliseconds and markup, UTF-16 SRT, ASS events, overlapping bilingual intervals, 5,000 dense cues and late track/part cancellation passed"
    )
    let q = try DMProto.request(cid: 300, index: 2)
    precondition(q == Data([16, 0xac, 2, 24, 1, 32, 2]))
    let closed = try DMProto.page(Data([16, 1]))
    precondition(closed.closed && closed.items.isEmpty)
    let bytes = Data([10, 7, 24, 9, 58, 3, 65, 66, 67, 16, 0])
    let p = try DMProto.page(bytes)
    precondition(!p.closed && p.items[0].text == "ABC" && p.items[0].mode == 9)
    let plus = try BulletVoteReceipt.reconcile(0, requested: true)
    let already = try BulletVoteReceipt.reconcile(65006, requested: true)
    let unset = try BulletVoteReceipt.reconcile(65004, requested: false)
    precondition(
      plus.count(2, wasLiked: false) == 3 && already.liked && already.count(4, wasLiked: false) == 4
        && !unset.liked && unset.count(4, wasLiked: true) == 4)
    try BulletComplaintReceipt.verify(data(#"{"code":0,"data":{"block":0}}"#))
    do {
      try BulletComplaintReceipt.verify(data(#"{"code":0,"data":{"block":-5}}"#))
      preconditionFailure()
    } catch let e as ServiceError { precondition(e.code == -5) }
    print(
      "Danmaku: exact mobile request, closed/open protobuf, inert mode 9, like/already liked and accepted/rejected complaint receipts passed"
    )
    if let path = CommandLine.arguments.dropFirst().first {
      let parsed = try DMProto.page(Data(contentsOf: URL(fileURLWithPath: path)))
      print(
        "Optional public sample: state=\(parsed.state), \(parsed.items.count) decoded comments, modes=\(Set(parsed.items.map(\.mode)).sorted())"
      )
    }
  }
}
