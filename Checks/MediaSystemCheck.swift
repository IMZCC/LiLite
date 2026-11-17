import Foundation

@main enum MediaSystemCheck {
  static func main() throws {
    var pip = SystemPiPLifecycle()
    precondition(!pip.end(samePlayer:true, background:true, continuePlaying:false))
    for same in [false, true] {
      for background in [false, true] {
        for keepAudio in [false, true] {
          for restored in [false, true] {
            pip.begin()
            if restored { pip.restore() }
            let pause = pip.end(samePlayer:same, background:background, continuePlaying:keepAudio)
            precondition(pause == (same && background && !keepAudio && !restored))
            precondition(!pip.started && !pip.restoring)
          }
        }
      }
    }
    let plain = URL(string:"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/01/v.m4s?deadline=1999999999")!
    let protected = URL(string:"https://upos-hz-mirrorakam.akamaized.net/upgcxcode/v.m4s?hdnts=dummy%2Ftest")!
    let bearer = URL(string:"https://upos-sz-mirrorcos.bilivideo.com/upgcxcode/v.m4s?token=fixture")!
    precondition(VODLine.akamai.candidate([plain,protected]) == protected && VODLine.akamai.candidate([plain]) == nil)
    precondition(VODLine.ali.candidate([protected,bearer]) == nil && VODLine.ali.candidate([plain])?.host == VODLine.ali.host)
    precondition(VODLine.ali.routes([protected,plain], audio:true, independent:true).first == plain)
    precondition(VODLine.baseUrl.routes([protected,plain], audio:true, independent:true).first == protected)
    for line in VODLine.allCases {
      let u = line.routes([protected,plain],audio:false,independent:false)
      precondition(!u.isEmpty && Set(u).count == u.count && u.allSatisfy { $0.scheme == "https" })
      precondition(!u.contains { $0.host != protected.host && $0.query?.contains("hdnts") == true })
    }
    precondition(DecoderPreference.routes(native:true,hardware:true,converts:true,enabled:false,settings:"videotoolbox") == [.software])
    precondition(DecoderPreference.routes(native:true,hardware:false,converts:false,enabled:false,settings:"auto").isEmpty)
    precondition(DecoderPreference.routes(native:true,hardware:true,converts:true,enabled:true,settings:"videotoolbox-copy,no") == [.copied,.software])
    var rules = NetworkMediaRules()
    let d = UserDefaults(suiteName:"Pili.Media.Fixture."+UUID().uuidString)!
    rules.wifiVideo=127; rules.cellVideo=32; rules.wifiAudio=30251; rules.cellAudio=30216
    rules.cellCodecs=["HEVC","AVC"]
    try rules.save(d); precondition(NetworkMediaRules.current(d) == rules && rules.codecOrder(cellular:false) != rules.codecOrder(cellular:true))
    d.removeObject(forKey:NetworkMediaRules.key)
    let https=URL(string:"https://i0.hdslb.com/x.jpg")!, signed=URL(string:"https://i0.hdslb.com/x.jpg?t=fixture")!
    let pic = GalleryPicture(https), secret = GalleryPicture(signed)
    precondition(pic.display(quality:12, minimum:55).lastPathComponent == "x.jpg@55q.webp" && secret.display(quality:10) == signed)
    precondition(ArtworkCacheRules.publicFile(https) && !ArtworkCacheRules.publicFile(signed))
    for rule in ["private", "max-age=100, no-store"] {
      precondition(!ArtworkCacheRules.admits(url:https,status:200,mime:"image/png",cookie:nil,control:rule))
    }
    print("PiP 16 close/restore/background/player combinations; 21 CDN routes and scoped signatures; decoder, cellular/wifi and public/signed artwork contracts passed")
  }
}
