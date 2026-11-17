import Foundation

/// Held only by the currently open editor. Original signed URLs never enter defaults, logs or imports.
struct ArchiveAddressGrant {
  let cid:Int64,owner:String,picture:[URL],sound:[URL]
  enum Choice { case issued(URL,URL?), external(URL,URL?) }
  var key:String{String(cid)+":"+owner}
  func pick(video:String,audio:String)throws->Choice{
    func parse(_ raw:String)throws->URL{
      let value=raw.trimmingCharacters(in:.whitespacesAndNewlines)
      guard !value.isEmpty,value.utf8.count<=16384,let c=URLComponents(string:value),c.scheme?.lowercased()=="https",
            let host=c.host,!host.isEmpty,c.user==nil,c.password==nil,c.fragment==nil,c.port==nil || c.port==443,let url=c.url else{throw ServiceError("请输入有效的 HTTPS 播放地址")}
      return url
    }
    let v=try parse(video),a=try audio.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty ? nil:parse(audio)
    if picture.contains(v),(a.map(sound.contains) ?? sound.isEmpty){return .issued(v,a)}
    let grants=picture+sound
    let issuedHosts=Set(grants.compactMap{$0.host?.lowercased()})
    let sensitive=Set(grants.compactMap{URLComponents(url:$0,resolvingAgainstBaseURL:false)}.flatMap{$0.queryItems ?? []}.compactMap{item ->String? in
      if ["deadline","expires","platform","build","qn","mid","mobi_app"].contains(item.name.lowercased()){return nil}
      guard let value=item.value,value.utf8.count>=8 else{return nil};return value
    })
    for u in [v,a].compactMap({$0}){
      let host=(u.host?.lowercased() ?? "").trimmingCharacters(in:CharacterSet(charactersIn:"."))
      let service=["bilibili.com","bilibili.tv","b23.tv","bilivideo.com","bilivideo.cn","biliapi.net","biliapi.com","hdslb.com","upos-hz-mirrorakam.akamaized.net"]
      guard !issuedHosts.contains(host),!service.contains(where:{host==$0 || host.hasSuffix("."+$0)}),
            !grants.contains(where:{$0.path==u.path && $0.query != nil}),
            !(URLComponents(url:u,resolvingAgainstBaseURL:false)?.queryItems ?? []).contains(where:{sensitive.contains($0.value ?? "")})
      else{throw ServiceError("此音视频地址不属于当前播放授权")}
    }
    return .external(v,a)
  }
}
