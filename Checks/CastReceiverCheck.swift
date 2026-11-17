import Foundation

protocol ObservableObject: AnyObject {}
@propertyWrapper struct Published<V> { var wrappedValue: V }
struct ServiceError: LocalizedError {
  let message: String
  init(_ m: String) { message = m }
  var errorDescription: String? { message }
}
@main enum RendererCheck {
  @MainActor static func main() async throws {
    let base = URL(string: CommandLine.arguments[1])!
    let udp = UInt16(CommandLine.arguments[2])!
    precondition(
      CastAddress.safe(base, fixture: true) && !CastAddress.safe(base)
        && !CastAddress.safe(URL(string: "http://example.org/device")!)
        && !CastAddress.safe(URL(string: "http://10.1.1.1@outside.example/device")!))
    func advertised(_ fields:[String:String],tcp:Bool=true)->URL? {
      CastBonjourLocation.description(peer:"192.168.1.8",name:"tv.local",port:49152,tcp:tcp,fields:fields)
    }
    precondition(advertised(["path":"/dlna/device.xml"])?.absoluteString=="http://192.168.1.8:49152/dlna/device.xml")
    precondition(advertised(["location":"http://tv.local:8080/upnp.xml"])?.absoluteString=="http://192.168.1.8:8080/upnp.xml")
    precondition(advertised(["url":"http://192.168.1.9/device.xml"])==nil && advertised(["path":"//example.org/tv"])==nil)
    precondition(advertised(["url":"file:///x"])==nil && advertised(["url":"http://me:pw@tv.local/test"])==nil)
    precondition(advertised([:],tcp:false)==nil)
    let events = CastSSDP.fixture(port: udp, seconds: 0.8)
    var found = Set<String>()
    var departed = false
    for try await a in events {
      if a.alive {
        if let url = a.location { found.insert(url.absoluteString) }
      } else {
        departed = true
      }
    }
    precondition(
      found == Set([base.appendingPathComponent("a/device.xml").absoluteString]) && departed)
    let h = CastHTTP(fixture: true)
    let a = try await h.device(base.appendingPathComponent("a/device.xml"))
    let b = try await h.device(base.appendingPathComponent("b/device.xml"))
    precondition(
      a.name == "家庭 & TV" && a.id == "uuid:receiver-a" && a.transport.urn.hasSuffix(":2")
        && a.endpoint.path == "/a/av" && a.render?.control.path == "/a/rc")
    let c = CastState(automatic: false)
    var held = 0
    var restored = -1.0
    var released = [String]()
    let local = CastLocalPlayback(
      position: { 37.8 }, hold: { held += 1 }, resume: { t in restored = t })
    let one = CastSubject.archive(
      bvid: ArchiveNumber.bv(123)!, aid: 123, cid: 55, title: "A & B <测试>", quality: 80)
    let two = CastSubject.episode(id: 300, cid: 67, title: "第二集", quality: 64)
    func lease(_ name: String) -> CastLease {
      CastLease(base.appendingPathComponent("lease/" + name + ".mp4"), mime: "video/mp4") {
        released.append(name)
      }
    }
    func toggle(_ k: String, _ value: Int) async throws {
      let (s, _) = try await h.request(base.appendingPathComponent("fixture/\(k)/\(value)"))
      precondition(s == 200)
    }
    try await c.start(subject: one, device: a, local: local, http: h) { _ in lease("first") }
    precondition(held == 1 && c.device == a && c.now.position == 37.8)
    await c.refresh()
    precondition(
      c.now.position == 37 && c.now.duration == 150 && c.now.state == .playing
        && c.now.muted == false && c.now.volume != nil)
    try await c.perform(.seek(83.9))
    try await c.perform(.volume(50))
    try await c.perform(.mute(true))
    try await c.perform(.pause)
    await c.refresh()
    precondition(
      c.now.position == 83 && c.now.state == .paused && c.now.muted == true
        && abs(c.now.volume! - 100 * 130 / 255.0) < 0.01)
    try await c.perform(.play)
    await c.refresh()
    precondition(c.now.state == .playing && c.now.position == 83)
    try await toggle("failPlayB", 1)
    do {
      try await c.start(subject: one, device: b, local: local, http: h) { _ in lease("rejected") }
      preconditionFailure()
    } catch CastProblem.fault(701, _) {}
    precondition(
      c.device == a && held == 1 && released.contains("rejected") && !released.contains("first"))
    try await toggle("failPlayB", 0)
    try await c.start(subject: one, device: b, local: local, http: h) { _ in lease("second") }
    await c.refresh()
    precondition(c.device == b && c.now.position == 83 && held == 2 && released.contains("first"))
    try await toggle("downB", 1)
    await c.refresh()
    await c.refresh()
    precondition(c.offline && c.device == b)
    try await toggle("downB", 0)
    try await c.reconnect(http: h) { subject, device in
      precondition(subject == one && device == b)
      return lease("retry")
    }
    await c.refresh()
    precondition(!c.offline && c.now.position == 83 && released.contains("second"))
    try await toggle("failOneB", 1)
    do {
      try await c.start(subject: two, device: b, local: local, http: h) { _ in
        lease("failReplacement")
      }
      preconditionFailure()
    } catch CastProblem.fault(701, _) {}
    await c.refresh()
    precondition(
      c.subject == one && c.device == b && c.now.position == 83 && c.now.state == .playing
        && released.contains("failReplacement") && !released.contains("retry"))
    try await c.start(subject: two, device: b, local: local, http: h) { _ in lease("episode") }
    await c.refresh()
    precondition(c.now.position == 37 && released.contains("retry"))
    try await c.perform(.seek(77))
    try await c.perform(.phone)
    precondition(c.device == nil && restored == 77 && released.contains("episode"))
    try await c.start(subject: one, device: a, local: local, http: h) { _ in lease("stranger") }
    try await toggle("foreignA", 1)
    do {
      try await c.perform(.stop)
      preconditionFailure()
    } catch CastProblem.foreign {}
    precondition(c.device == nil && released.contains("stranger"))
    try await toggle("foreignA", 0)
    try await c.start(subject: one, device: a, local: local, http: h) { _ in lease("noTrack") }
    try await toggle("noTrackURI", 1)
    try await toggle("foreignA", 1)
    await c.refresh()
    precondition(c.device == nil && released.contains("noTrack"))
    try await toggle("noTrackURI", 0)
    try await toggle("foreignA", 0)
    try await c.start(subject: one, device: b, local: local, http: h) { _ in lease("offlineReturn")
    }
    try await c.perform(.seek(60))
    try await toggle("downB", 1)
    await c.refresh()
    await c.refresh()
    try await c.perform(.phone)
    precondition(c.device == nil && restored == 60 && released.contains("offlineReturn"))
    let alias = CastAddress.child(
      "http://tv.local:1234/a", from: base, fixture: true, alias: "tv.local")
    precondition(
      alias?.host == "127.0.0.1" && alias?.port == 1234
        && CastAddress.child("http://x.local/soap", from: base, fixture: true, alias: "tv.local")
          == nil
    )
    do {
      _ = try await h.device(base.appendingPathComponent("redirect"))
      preconditionFailure()
    } catch {}
    do {
      _ = try await h.device(base.appendingPathComponent("oversize"))
      preconditionFailure()
    } catch {}
    do {
      _ = try CastProtocol.device(
        Data(#"<root><URLBase>http://192.168.4.3/</URLBase></root>"#.utf8), url: base, fixture: true
      )
      preconditionFailure()
    } catch {}
    let source = one.fields(token: nil)
    precondition(
      source["is_proj"] == "1" && source["object_id"] == "123" && source["playurl_type"] == "1"
        && source["qn"] == "80" && source["access_key"] == nil
        && source["mobi_app"] == "android" && source["platform"] == "android")
    precondition(two.fields(token: nil)["playurl_type"] == "2")
    func grant(_ json: String) throws -> [URL] {
      let p = try JSONDecoder().decode(
        ArchiveGrantResponse<CastGrantBody>.self, from: Data(json.utf8))
      return try p.body.routes(guest: true, grant: p.grant)
    }
    let valid = try grant(
      #"{"quality":64,"durl":[{"url":"https://media.example.invalid/a","backup_url":["https://media.example.invalid/b","https://media.example.invalid/a"]}]}"#
    )
    precondition(valid.count == 2)
    let televisionHTTP = try grant(#"{"quality":64,"durl":[{"url":"http://media.example.invalid/tv.mp4"}]}"#)
    precondition(televisionHTTP.first?.scheme == "http")
    for attr in [
      #""is_preview":1"#, #""is_drm":1"#, #""drm_type":2"#, #""accept_description":["试看"]"#,
      #""support_formats":[{"quality":64,"need_vip":true}]"#,
    ] {
      do {
        _ = try grant(
          "{\"quality\":64," + attr + ",\"durl\":[{\"url\":\"https://media.example.invalid/a\"}]}")
        preconditionFailure()
      } catch {}
    }
    print(
      "Loopback SSDP/NOTIFY, AVTransport v2, renderer volume 0…255, SOAP faults, two-device handoff, position/seek, source switch, disconnect/reconnect, local resume, foreign URI and projection grants passed"
    )
  }
}
