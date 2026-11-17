import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

@main enum BackupCheck {
  typealias Map = BackupFormat.Map
  struct Step {
    let verb: String, path: String, status: Int, response: Data, etag: String?
    init(
      _ verb: String, _ path: String, _ status: Int, _ response: Data = Data(),
      _ etag: String? = nil
    ) {
      self.verb = verb
      self.path = path
      self.status = status
      self.response = response
      self.etag = etag
    }
  }
  final class Script {
    var steps: [Step], requests: [URLRequest] = []
    init(_ s: [Step]) { steps = s }
    func send(_ r: URLRequest) async throws -> DAVReply {
      precondition(!steps.isEmpty)
      let step = steps.removeFirst()
      precondition(r.httpMethod == step.verb && r.url!.path.hasSuffix(step.path))
      precondition(r.value(forHTTPHeaderField: "Authorization") == "Basic dTpw")
      if r.httpMethod == "PROPFIND" { precondition(r.value(forHTTPHeaderField: "Depth") == "0") }
      requests.append(r)
      return .init(status: step.status, data: step.response, etag: step.etag)
    }
  }
  static func rejects(_ action: () throws -> Void) {
    do {
      try action()
      preconditionFailure("unexpected success")
    } catch {}
  }
  static func main() async throws {
    let split =
      try BackupFormat.Kind.splitRatio.convert([57.25, 42.75], importing: true) as? Double
    let pair = try BackupFormat.Kind.splitRatio.convert(split ?? 0, importing: false) as? [Double]
    precondition(pair == [57.25, 42.75])
    for invalid: [Any] in [[true, 99], [91, 9], [60, 30], [50]] {
      rejects { _ = try BackupFormat.Kind.splitRatio.convert(invalid, importing: true) }
    }
    let dm: Map = ["setting": ["fontWeight": 0, "danmakuOpacity": 0, "danmakuShowArea": 0.1,
       "subtitleFontScale": 0.5, "subtitleFontScaleFS": 2.5, "subtitleFontWeight": 8,
       "danmakuFontScale": 0.5, "danmakuFontScaleFS": 2.5, "danmakuBlockType": [2, 6, 7, 99]], "video": Map()]
    let restoredDM = try BackupFormat.native(dm, current: [:]).0
    let captions = (restoredDM["controls"] as! Map)["numbers"] as! Map
    precondition(restoredDM["subtitleSize"] as? Double == 8 && captions["caption.fullSize"] as? Double == 40 && captions["caption.weight"] as? Int == 9)
    let style = restoredDM["danmakuStyle"] as! Map
    precondition(restoredDM["dmSize"] as? Double == 7.5 && restoredDM["fullDmSize"] as? Double == 37.5)
    precondition(style["fontWeight"] as? Int == 1 && style["monochrome"] as? Bool == true && style["hideBottom"] as? Bool == false)
    let dmExport = try BackupFormat.read(BackupFormat.export(native: restoredDM, over: dm))
    let set = dmExport["setting"] as! Map
    precondition(set["fontWeight"] as? Int == 0 && set["danmakuBlockType"] as? [Int] == [2,6,7,99])
    let legacyWeight: Map = ["setting": ["fontWeight":9], "video":Map(), "piliNative":["version":1,"danmakuStyle":["fontWeight":9]]]
    let oldDM = try BackupFormat.native(legacyWeight,current:[:]).0
    precondition((oldDM["danmakuStyle"] as? Map)?["fontWeight"] as? Int == 9)
    let pinnedLayout: Map = ["setting": ["navBarSort":[2,1], "tabBarSort":[5,0], "defaultHomePage":0,
      "alwaysExapndIntroPanel":true, "exapndIntroPanelH":false, "showDynDecorate":true, "videoSync":"display-adrop", "autosync":"30",
      "appFont":"/localFont", "appFontWeightV2":0, "textScale":1.4], "video":["cacheVideoFit":8]]
    let importedLayout = try BackupFormat.native(pinnedLayout,current:[:]).0
    let restoredClock = try BackupFormat.read(BackupFormat.export(native: importedLayout))["setting"] as! Map
    precondition(restoredClock["videoSync"] as? String == "display-adrop" && restoredClock["autosync"] as? String == "30")
    let layout = importedLayout["layout"] as! Map, font = importedLayout["typeface"] as! Map
    precondition(layout["tabs"] as? [String] == ["mine","dynamics"] && layout["launch"] as? String == "mine")
    precondition(layout["channels"] as? [String] == ["影视","直播"] && importedLayout["gravity"] as? String == "sixteenNine")
    precondition(font["name"] == nil && font["weight"] as? Int == 1 && font["scale"] as? Double == 1.4)
    let nativeTabs: Map = ["version":1,"layout":["tabs":["home","search","mine"],"launch":"search"]]
    let restoredTabs = try BackupFormat.native(BackupFormat.read(BackupFormat.export(native:nativeTabs)),current:[:]).0
    precondition((restoredTabs["layout"] as! Map)["tabs"] as? [String] == ["home","search","mine"])
    precondition((restoredTabs["layout"] as! Map)["launch"] as? String == "search")
    let shuffleNative: Map = ["version": 1, "listenRepeat": "随机播放"]
    let exportedShuffle = try BackupFormat.export(
      native: shuffleNative, over: ["setting": ["audioPlayMode": 3], "video": Map()])
    let shuffleArchive = try JSONSerialization.jsonObject(with: exportedShuffle) as! Map
    let (restoredShuffle, _) = try BackupFormat.native(shuffleArchive, current: [:])
    precondition(
      (shuffleArchive["setting"] as? Map)?["audioPlayMode"] == nil
        && restoredShuffle["listenRepeat"] as? String == "随机播放")
    let paused = try BackupFormat.Kind.audioMode.convert(0, importing: true) as? String
    let cycleIndex = try BackupFormat.Kind.audioMode.convert("列表循环", importing: false) as? Int
    precondition(paused == "播完暂停" && cycleIndex == 3)
    let noTint = try BackupFormat.Kind.nightARGB.convert(NSNull(), importing: true) as? Int
    let exportedTint = try BackupFormat.Kind.nightARGB.convert(noTint ?? -1, importing: false)
    let packed = try BackupFormat.Kind.nightARGB.convert(0x8799_aabb, importing: true) as? Int
    precondition(noTint == Int(UInt32.max) && exportedTint is NSNull && packed == 0x8799_aabb)
    let mask = try BackupFormat.Kind.unreadKinds.convert([0, 3, 4, 3], importing: true) as? Int
    let ids = try BackupFormat.Kind.unreadKinds.convert(mask ?? -1, importing: false) as? [Int]
    precondition(mask == 25 && ids == [0, 3, 4])
    do {
      _ = try BackupFormat.Kind.unreadKinds.convert([true], importing: true)
      preconditionFailure("boolean unread index accepted")
    } catch {}
    let big = "9223372036854775701"
    let upstreamID = try BackupFormat.read(
      Data(("{\"setting\":{\"quickFavId\":" + big + "},\"video\":{}}").utf8))
    let migrated = try BackupFormat.native(upstreamID, current: [:]).0
    precondition((migrated["controls"] as? Map)?["quickFolder"] as? String == big)
    let exported = try BackupFormat.read(BackupFormat.export(native: migrated))
    precondition(((exported["setting"] as? Map)?["quickFavId"] as? NSNumber)?.stringValue == big)
    let source = Data(
      #"{"setting":{"themeMode":1,"showVideoReply":false,"badCertificateCallback":true,"subtitleBgOpaticy":0.4,"fontWeight":7,"nextVersion":[3]},"video":{"speedsList":[0.75,1,2],"longPressSpeedDefault":2.75}}"#
        .utf8)
    let archive = try BackupFormat.read(source)
    let (m, skip) = try BackupFormat.native(archive, current: ["accent": "rose"])
    let ctrl = m["controls"] as! Map
    precondition(
      skip == 1 && m["appearance"] as? String == "dark" && m["accent"] as? String == "rose")
    precondition(
      (ctrl["flags"] as! Map)["detail.replies"] as? Bool == false
        && (ctrl["flags"] as! Map)["network.allowInvalidCertificates"] as? Bool == true
        && (ctrl["numbers"] as! Map)["player.holdSpeed"] as? Double == 2.75)
    precondition((m["danmakuStyle"] as! Map)["fontWeight"] as? Int == 8)
    var prepared = m
    prepared["version"] = 1
    let dual = try BackupFormat.read(BackupFormat.export(native: prepared, over: archive))
    precondition((dual["setting"] as! Map)["nextVersion"] as? [Int] == [3])
    precondition((dual["setting"] as! Map)["badCertificateCallback"] as? Bool == true)
    let local = try BackupFormat.read(BackupFormat.export(native: prepared))
    precondition((local["setting"] as! Map)["nextVersion"] == nil)
    let round = try BackupFormat.native(dual, current: [:]).0
    precondition((round as NSDictionary).isEqual(prepared as NSDictionary))
    let legacy = try BackupFormat.native(["version": 1, "rate": 1.5], current: [:]).0
    precondition(legacy["rate"] as? Double == 1.5)
    for json in [
      #"{"setting":{"searchSuggestion":1},"video":{}}"#,
      #"{"setting":{"badCertificateCallback":1},"video":{}}"#,
      #"{"setting":{"danmakuWeight":false},"video":{}}"#, #"{"video":[],"setting":{}}"#,
      #"{"unrelated":1}"#,
    ] {
      rejects { _ = try BackupFormat.native(BackupFormat.read(Data(json.utf8)), current: [:]) }
    }
    let fields = BackupFormat.fields.map { $0.box + "/" + $0.key }
    precondition(Set(fields).count == fields.count)
    let dir = try DAVLocation(
      address: "https://backup.example/dav", directory: "/我 的/", tablet: false)
    let folder = "/我 的"
    let app = "/PiliPlus"
    let file = "/piliplus_settings_phone.json"
    precondition(dir.folders.count == 2 && dir.file.path.hasSuffix(app + file))
    let pad = try DAVLocation(address: "https://backup.example/dav/", directory: "/", tablet: true)
    precondition(pad.file.path.hasSuffix("/PiliPlus/piliplus_settings_pad.json"))
    let legacyURL = try DAVLocation(
      address: "https://backup.example/dav/prefs.json", directory: "/", tablet: false)
    precondition(legacyURL.folders.isEmpty && legacyURL.file.path == "/dav/prefs.json")
    for u in [
      "ftp://backup.example", "https://user@backup.example", "https://backup.example/dav?q=a",
      "https://backup.example/dav/%2e%2e", "https://backup.example/a%2fb",
    ] {
      rejects { _ = try DAVLocation(address: u, directory: "/", tablet: false) }
    }
    for (base, alias) in [
      ("http://backup.example/dav", "http://backup.example:80/dav/PiliPlus/piliplus_settings_phone.json"),
      ("https://backup.example/dav", "https://backup.example:443/dav/PiliPlus/piliplus_settings_phone.json"),
      ("http://192.168.1.8:8080/dav", "http://192.168.1.8:8080/dav/PiliPlus/piliplus_settings_phone.json"),
      ("http://[::1]:8080/dav", "http://[::1]:8080/dav/PiliPlus/piliplus_settings_phone.json"),
    ] {
      let location = try DAVLocation(address: base, directory: "/", tablet: false)
      let dav = DAVStore(location: location, user: "", password: "") { _ in preconditionFailure("URL checks must not send requests") }
      precondition(dav.managedURL(alias) == location.file)
      precondition(dav.managedURL("piliplus_settings_phone.json") == location.file)
      precondition(dav.managedURL(location.file.path) == location.file)
      let foreign = URL(string: alias)!.scheme == "http" ? alias.replacingOccurrences(of: "http://", with: "https://") : alias.replacingOccurrences(of: "https://", with: "http://")
      precondition(dav.managedURL(foreign) == nil)
    }
    let plainFile = try DAVLocation(address: "http://backup.example/dav/prefs.json", directory: "/", tablet: false)
    let plainStore = DAVStore(location: plainFile, user: "", password: "") { _ in preconditionFailure() }
    precondition(plainStore.managedURL("http://backup.example:80/dav/prefs.json") == plainFile.file)
    precondition(plainStore.managedURL("http://backup.example:443/dav/prefs.json") == nil)
    precondition(SelfHostedServiceURL.allowsReadRedirect(method: "GET", from: URL(string: "http://backup.example")!, to: URL(string: "http://backup.example:80/status")!))
    precondition(!SelfHostedServiceURL.allowsReadRedirect(method: "POST", from: URL(string: "http://backup.example")!, to: URL(string: "http://backup.example/status")!))
    let sponsorBase = SelfHostedServiceURL.parse("http://192.168.1.8:3030/sponsor")!
    let request = try SponsorAPIRequest.make(base: sponsorBase, path: "skipSegments", query: ["videoID": "BV1", "cid": "1"])
    precondition(request.url?.scheme == "http" && request.url?.port == 3030 && request.url?.path == "/sponsor/api/skipSegments")
    precondition(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
    precondition(SponsorAPIRequest.defaultServer == "https://www.bsbsb.top")
    for bad in ["a/../b", "%2f", "a\\b"] {
      rejects {
        _ = try DAVLocation(address: "https://backup.example/dav", directory: bad, tablet: false)
      }
    }
    let xml = Data(
      #"<D:multistatus xmlns:D="DAV:"><D:response><D:href>/</D:href><D:propstat><D:prop><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response></D:multistatus>"#
        .utf8)
    let create = Script([
      .init("PROPFIND", folder, 404), .init("MKCOL", folder, 201), .init("PROPFIND", app, 404),
      .init("MKCOL", app, 405), .init("PROPFIND", app, 207, xml), .init("GET", file, 404),
      .init("PUT", file, 201),
    ])
    func store(_ s: Script) -> DAVStore {
      .init(location: dir, user: "u", password: "p", send: s.send)
    }
    try await store(create).write { old in
      precondition(old == nil)
      return source
    }
    precondition(
      create.steps.isEmpty
        && create.requests.last?.value(forHTTPHeaderField: "If-None-Match") == "*")
    let overwrite = Script([
      .init("PROPFIND", folder, 207, xml), .init("PROPFIND", app, 207, xml),
      .init("GET", file, 200, source, "\"v1\""), .init("PUT", file, 412),
    ])
    do {
      try await store(overwrite).write { d in
        precondition(d == source)
        return Data("new".utf8)
      }
      preconditionFailure()
    } catch {
      precondition(
        overwrite.steps.isEmpty
          && overwrite.requests.last?.value(forHTTPHeaderField: "If-Match") == "\"v1\"")
    }
    let wrong = Script([.init("PROPFIND", folder, 207, Data("<collection/>".utf8))])
    do {
      try await store(wrong).prepare()
      preconditionFailure()
    } catch { precondition(wrong.steps.isEmpty) }
    let redirected = Script([.init("GET", file, 302)])
    do {
      _ = try await store(redirected).read()
      preconditionFailure()
    } catch { precondition(redirected.steps.isEmpty) }
    print(
      "Backup: legacy, upstream and native field migration, no cross-target carryover, DAV collection checks, conditional PUT and read-only restore passed"
    )
  }
}
