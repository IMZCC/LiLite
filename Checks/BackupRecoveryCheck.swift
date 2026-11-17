import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private final class DAVFixtureAuthentication: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  let policy: SelfHostedHTTPAuthentication
  init(_ origin: URL) { policy = .init(origin: origin, user: "fixture", password: "fake") }
  func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
    if let credential = policy.credential(for: challenge) { completionHandler(.useCredential, credential) }
    else { completionHandler(.cancelAuthenticationChallenge, nil) }
  }
}

@main enum BackupRecoveryCheck {
  static func mustFail(_ body: () async throws -> Void) async {
    do {
      try await body()
      fatalError("invalid input or lost precondition accepted")
    } catch {}
  }
  static func main() async throws {
    let args = CommandLine.arguments
    guard args.count == 3, let port = Int(args[2]) else {
      fatalError("requires isolated temp folder and loopback port")
    }
    let dir = URL(fileURLWithPath: args[1], isDirectory: true)
    let key = "Synthetic跨设备-password-é"
    let payload = Data("synthetic portable backup fixture only".utf8)
    let independent = try Data(contentsOf: dir.appendingPathComponent("independent.pilipack"))
    let fromPython = try DataPackCipher.decrypt(independent, password: key)
    precondition(fromPython == payload)
    let one = try DataPackCipher.encrypt(
      payload, password: key.decomposedStringWithCanonicalMapping)
    let two = try DataPackCipher.encrypt(payload, password: key)
    precondition(one != two && !one.contains(payload) && DataPackCipher.sealed(one))
    try one.write(to: dir.appendingPathComponent("swift.pilipack"))
    for offset in [0, 8, 12, 28, 37, one.count - 1] {
      var corrupt = one
      corrupt[offset] ^= 0x01
      await mustFail { _ = try DataPackCipher.decrypt(corrupt, password: key) }
    }
    await mustFail {
      _ = try DataPackCipher.decrypt(one, password: "synthetic incorrect passphrase")
    }
    await mustFail { _ = try DataPackCipher.encrypt(payload, password: "short") }
    let isolatedName = "PiliFixture.restore." + UUID().uuidString
    let isolated = UserDefaults(suiteName: isolatedName)!
    defer { isolated.removePersistentDomain(forName: isolatedName) }
    isolated.set("old", forKey: "quality")
    isolated.set("keep", forKey: "unrelated")
    isolated.set("old folder", forKey: "folder")
    await mustFail {
      _ = try StagedPreferences.collect(removing: ["folder"]) { stage in
        stage.set("new", forKey: "quality")
        throw ServiceError("injected invalid settings")
      }
    }
    precondition(
      isolated.string(forKey: "quality") == "old"
        && isolated.string(forKey: "folder") == "old folder")
    try StagedPreferences.collect(removing: ["folder"]) { $0.set("new", forKey: "quality") }.commit(
      isolated)
    precondition(
      isolated.string(forKey: "quality") == "new" && isolated.object(forKey: "folder") == nil
        && isolated.string(forKey: "unrelated") == "keep")
    let archive = ReplyArchive(directory: dir.appendingPathComponent("replies"))
    let record: [String: Any] = [
      "id": "7", "oid": "8", "type": "1", "ctime": "2",
      "member": ["mid": "101", "uname": "fixture"],
      "content": [
        "message": "fixture",
        "pictures": [["imgSrc": "https://image.invalid/fixture", "imgWidth": 9]],
      ],
    ]
    let synthetic = SavedReply.parse(record)!
    let other = SavedReply.parse([
      "id": "8", "oid": "8", "type": "1", "content": ["message": "concurrent"],
    ])!
    try await archive.merge([other], uid: "202")
    let receipt = try await archive.mergeForPack([synthetic], uid: "101")
    let exported = try await archive.export("101")
    let restored = try JSONSerialization.jsonObject(with: exported) as! [[String: Any]]
    precondition((restored.first?["member"] as? [String: Any])?["uname"] as? String == "fixture")
    let unchanged = try await archive.export("202")
    var tx = DataPackRestoreJournal()
    tx.wrote { try await archive.rollbackPack(receipt, uid: "101") }
    let reason = await tx.rollback(ServiceError("injected locked Keychain"))
    let after = try await archive.items("101")
    let unaffected = try await archive.export("202")
    precondition(
      after.isEmpty && unaffected == unchanged
        && reason.localizedDescription == "injected locked Keychain")
    let receipt2 = try await archive.mergeForPack([synthetic], uid: "101")
    try await archive.merge([other], uid: "101")
    await mustFail { try await archive.rollbackPack(receipt2, uid: "101") }
    let kept = try await archive.items("101")
    precondition(kept.count == 2)
    let raw = try BackupFormat.read(
      Data(
        #"{"setting":{"windowSize":[300,400],"webdavPassword":"SYNTHETIC","webdavUri":"https://fixture.invalid","badCertificateCallback":true,"downloadPath":"/fake/device"},"video":{}}"#
          .utf8))
    let carry = BackupFormat.remainder(raw)
    let imported = try BackupFormat.native(raw, current: ["version": 1]).0
    let plain = try BackupFormat.export(
      native: imported, over: BackupFormat.mergedCarry(carry, raw))
    let obj = try BackupFormat.read(plain)
    let set = obj["setting"] as! [String: Any]
    precondition(
      set["windowSize"] as? [Int] == [300, 400] && set["webdavPassword"] == nil
        && set["webdavUri"] == nil && set["badCertificateCallback"] as? Bool == true
        && set["downloadPath"] == nil)
    let replaced = BackupFormat.restorationBase(
      ["setting": [String: Any](), "video": [String: Any]()],
      current: [
        "appearance": "dark", "guestDevice": "synthetic-device", "accent": "blue",
        "controls": ["flags": ["detail.replies": false]],
      ],
      defaults: [
        "appearance": "system", "guestDevice": "different", "controls": ["flags": [String: Any]()],
      ])
    precondition(
      replaced["appearance"] as? String == "system"
        && replaced["guestDevice"] as? String == "synthetic-device"
        && replaced["accent"] as? String == "blue"
        && ((replaced["controls"] as? [String: Any])?["flags"] as? [String: Any])?["detail.replies"]
          == nil
    )
    let sparse = try BackupFormat.native(
      ["version": 1, "appearance": "dark"],
      current: ["version": 1, "rate": 1.5, "appearance": "system"]
    ).0
    precondition(sparse["rate"] as? Double == 1.5 && sparse["appearance"] as? String == "dark")
    let origin = URL(string: "http://127.0.0.1:\(port)")!
    let target = try DAVLocation(address: origin.absoluteString, directory: "/", tablet: false)
    let cfg = URLSessionConfiguration.ephemeral
    cfg.httpCookieStorage = nil
    cfg.urlCredentialStorage = nil
    cfg.connectionProxyDictionary = [:]
    let session = URLSession(configuration: cfg)
    defer { session.invalidateAndCancel() }
    let dav = DAVStore(location: target, user: "fixture", password: "fake") { request in
      guard let remote = request.url, SelfHostedServiceURL.sameOrigin(remote, origin)
      else { fatalError("credential domain escaped") }
      let (d, r) = try await session.data(for: request)
      let h = r as! HTTPURLResponse
      return DAVReply(
        status: h.statusCode, data: d, etag: h.value(forHTTPHeaderField: "ETag"),
        modified: h.value(forHTTPHeaderField: "Last-Modified"))
    }
    for href in [
      "https://outside.invalid/PiliPlus/piliplus_settings_phone.json",
      "/other/piliplus_settings_phone.json",
      "/PiliPlus/%2e%2e/PiliPlus/piliplus_settings_phone.json",
      "/PiliPlus/../PiliPlus/piliplus_settings_phone.json",
      "/PiliPlus/%252e/piliplus_settings_phone.json",
      "/PiliPlus/piliplus_settings_phone.json?next=1", "/PiliPlus/not-mine.json",
    ] { precondition(dav.managedURL(href) == nil) }
    let first = try await dav.contents()
    precondition(first.count == 1 && first[0].name == "piliplus_settings_phone.json")
    let f = first[0]
    let old = try await dav.read(f)
    precondition(old == Data("original".utf8))
    try await dav.write { b in
      precondition(b == old)
      return Data("new".utf8)
    }
    await mustFail { _ = try await dav.read(f) }
    await mustFail { try await dav.delete(f) }
    try await dav.snapshot(plain, encrypted: false)
    try await dav.snapshot(one, encrypted: true)
    let list = try await dav.contents()
    precondition(list.count == 3)
    let entry = list.first(where: \.encrypted)!
    let archived = try await dav.read(entry)
    let recovered = try DataPackCipher.decrypt(archived, password: key)
    precondition(recovered == payload)
    try await dav.delete(entry)
    let next = try await dav.contents()
    precondition(next.count == 2 && !next.contains(where: \.encrypted))
    let direct = try DAVLocation(
      address: origin.appendingPathComponent("PiliPlus/piliplus_settings_phone.json").absoluteString, directory: "ignored",
      tablet: true)
    let fixed = DAVStore(location: direct, user: dav.user, password: dav.password, send: dav.send)
    let single = try await fixed.contents()
    precondition(
      single.count == 1 && fixed.managedURL("/PiliPlus/piliplus_settings_pad.json") == nil)
    let second = "Thu, 12 Nov 2026 10:20:30 GMT"
    let version = DAVEntry(url:URL(string:"https://example.invalid/backup")!,etag:nil,modified:second,size:12)
    precondition(version.overwriteCondition(responseDate:second) == nil)
    precondition(version.overwriteCondition(responseDate:nil) == nil)
    precondition(version.overwriteCondition(responseDate:"Thu, 12 Nov 2026 10:20:31 GMT") == nil)
    precondition(version.overwriteCondition(responseDate:"Thu, 12 Nov 2026 10:21:30 GMT")?["If-Unmodified-Since"] == second)
    let tagged = DAVEntry(url:version.url, etag:"\"reviewed\"", modified:second, size:12)
    precondition(tagged.overwriteCondition(responseDate:second)?["If-Match"] == "\"reviewed\"")
    let authentication = SelfHostedHTTPAuthentication(origin: origin, user: "fixture", password: "fake")
    let challenge = "Digest realm=\"FixtureDAV\", nonce=\"isolated-nonce\", qop=\"auth\""
    var probe = URLRequest(url: origin.appendingPathComponent("digest/preferences.json"))
    probe.httpMethod = "GET"
    let authenticated = try authentication.retry(probe, challenge: challenge)!
    let repeatAttempt = try authentication.retry(authenticated, challenge: challenge)
    precondition(repeatAttempt == nil)
    for escaped in ["http://outside.invalid/digest/preferences.json", "https://127.0.0.1:\(port)/digest/preferences.json", "http://127.0.0.1:\(port == 65535 ? port - 1 : port + 1)/digest/preferences.json"] {
      probe.url = URL(string: escaped)
      let outsideAttempt = try authentication.retry(probe, challenge: challenge)
      precondition(outsideAttempt == nil)
    }
    for variant in ["digest", "digest-md5-sess", "digest-sha256", "digest-sha256-sess", "digest-authint", "digest-stale"] {
    let digestTarget = try DAVLocation(address: origin.appendingPathComponent(variant + "/preferences.json").absoluteString, directory: "/", tablet: false)
    let digestSession = URLSession(configuration: cfg, delegate: DAVFixtureAuthentication(origin), delegateQueue: nil)
    defer { digestSession.invalidateAndCancel() }
    let digest = DAVStore(location: digestTarget, user: "fixture", password: "fake") { request in
      var nextRequest = request
      var result = try await digestSession.data(for: nextRequest)
      for _ in 0..<2 {
      if let http = result.1 as? HTTPURLResponse, http.statusCode == 401,
        let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate"),
        let next = try SelfHostedHTTPAuthentication(origin: origin, user: "fixture", password: "fake").retry(nextRequest, challenge: challenge) {
        nextRequest = next
        result = try await digestSession.data(for: next)
      } else { break }
      }
      let (data, response) = result
      let reply = response as! HTTPURLResponse
      return .init(status: reply.statusCode, data: data, etag: reply.value(forHTTPHeaderField: "ETag"))
    }
    try await digest.write { old in precondition(old == Data("digest-before".utf8)); return Data("digest-after".utf8) }
    let digestRead = try await digest.read()
    precondition(digestRead == Data("digest-after".utf8))
    }
    let sponsor = origin.appendingPathComponent("sponsor")
    for (path, method, query, body) in [
      ("status/uptime", "GET", [String: String](), nil as [String: Any]?),
      ("skipSegments", "GET", ["videoID": "BV-fixture", "cid": "1"], nil),
      ("skipSegments", "POST", [:], ["videoID": "BV-fixture", "cid": "1", "userID": "synthetic-private-service-id", "segments": [["segment": [1, 2], "category": "sponsor", "actionType": "skip"]]]),
    ] {
      let request = try SponsorAPIRequest.make(base: sponsor, path: path, method: method, query: query, body: body)
      let (bytes, response) = try await session.data(for: request)
      precondition((response as? HTTPURLResponse)?.statusCode == 200)
      if path == "status/uptime" { precondition(String(decoding: bytes, as: UTF8.self) == "3600") }
      else { let rows = try JSONSerialization.jsonObject(with: bytes) as! [[String: Any]]; precondition(rows.count == 1) }
    }
    print(
      "Backup recovery: portable password interoperability, rollback, real HTTP WebDAV Basic/Digest read-write and revision guards, relative/same-origin PROPFIND and HTTP Sponsor GET/POST without account credentials passed"
    )
  }
}
