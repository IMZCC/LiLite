import Foundation
#if !canImport(Combine)
protocol ObservableObject:AnyObject{}
@propertyWrapper struct Published<Value>{var wrappedValue:Value}
#endif
@main enum ArchiveDetailCheck{
  static func main()async throws{
    let decoder=JSONDecoder()
    let specimen=#"{"view_points":[{"type":2,"from":0,"to":6,"content":"章节一","imgUrl":"https://img.example/1.jpg"},{"type":7,"from":3},{"from":"nope"},{"type":2,"from":6,"to":12}],"interaction":{"graph_version":3}}"#
    let positions=try decoder.decode(VideoPositions.self,from:Data(specimen.utf8))
    precondition(positions.chapters.count==2 && positions.chapters[0].imgUrl != nil && positions.chapters[0].end(next:6,duration:12)==6 && positions.interaction?.graph_version==3)
    let f=try decoder.decode(VideoPositions.self,from:Data(#"{"view_points":[{"type":1,"from":2} ]}"#.utf8));precondition(f.chapters.isEmpty)
    let parts=[Video.Part(cid:11,page:1,part:"首段"),Video.Part(cid:22,page:2,part:"接续")]
    let remote=ServiceWatchPoint(last_play_cid:22,last_play_time:12500)
    let start=ArchiveStart.select(parts,fallback:11,page:nil,from:nil,continuePart:false,local:22,remote:remote,saveTime:true)
    let offer=ArchiveStart.offer(parts,current:start?.cid,enabled:true,local:22,remote:remote,keepTime:true)
    precondition(start?.cid==11 && start?.seconds==nil && offer?.cid==22 && offer?.seconds==12.5)
    precondition(ArchiveStart.offer(parts,current:22,enabled:true,local:22,remote:remote,keepTime:true)==nil)
    precondition(ArchiveStart.offer(parts,current:11,enabled:false,local:22,remote:remote,keepTime:true)==nil)
    let bv=ArchiveNumber.bv(170001)!
    let url=ArchiveSharePoint.archive(bv,page:2,time:21.125)!
    let eps=ArchiveSharePoint.episode(222,course:true,time:4.25)!
    precondition(url.query=="p=2&t=21.125" && eps.path=="/cheese/play/ep222" && eps.query=="t=4.250")
    precondition(ArchiveSharePoint.archive(bv,page:1,time:.infinity)?.query==nil && ArchiveSharePoint.archive("bogus",page:2)==nil)
    let v=URL(string:"https://media.invalid/issued/video.m4s?sig=sample-only-signature")!,a=URL(string:"https://media.invalid/issued/audio.m4s?sig=another-demonstration")!
    let g=ArchiveAddressGrant(cid:4,owner:"fixture",picture:[v],sound:[a])
    guard case .issued(let pv,let pa)=try g.pick(video:v.absoluteString,audio:a.absoluteString),pv==v,pa==a else{preconditionFailure()}
    guard case .external(let independent,_)=try g.pick(video:"https://example.org/movie.mp4",audio:""),independent.host=="example.org" else{preconditionFailure()}
    for (x,y) in [(v.absoluteString,"https://example.org/a.m4a"),("https://example.org/movie?sig=sample-only-signature",""),("https://example.org/issued/video.m4s",""),("https://app.bilibili.com/api",""),("https://x:y@example.org/movie",""),("file:///local/movie",""),(a.absoluteString,v.absoluteString)]{
      do{_=try g.pick(video:x,audio:y);preconditionFailure("mixed or stale grant accepted")}catch{}
    }
    var relation=try decoder.decode(VideoEngagement.self,from:Data(#"{"like":false,"dislike":1,"coin":0}"#.utf8))
    precondition(relation.disliked && !relation.liked)
    relation.addTriple(try decoder.decode(VideoEngagement.self,from:Data(#"{"like":true,"fav":1,"coin":true}"#.utf8)))
    precondition(relation.complete && !relation.disliked)
    guard CommandLine.arguments.count==4 else{fatalError("need independent silent movie, audio track and destination")}
    let video=try LocalMediaFile(URL(fileURLWithPath:CommandLine.arguments[1])),sound=try LocalMediaFile(URL(fileURLWithPath:CommandLine.arguments[2]))
    let vi=try LocalMovieFragments.track(video,audio:false),ai=try LocalMovieFragments.track(sound,audio:true)
    precondition(!vi.fragments.isEmpty && !ai.fragments.isEmpty && vi.codec != ai.codec)
    let dir=URL(fileURLWithPath:CommandLine.arguments[3])
    for (track,name) in [(vi,"v"),(ai,"a")]{
      let data=try track.file.data(0,Int(track.file.length))
      try data.write(to:dir.appendingPathComponent(name+"-out.mp4"))
    }
    do{_=try LocalMovieFragments.track(sound,audio:false);preconditionFailure()}catch{}
    print("Archive detail: independent chapter decoding, precise part/course links, same-grant track admission and cross-origin rejection, confirmed dislike/triple state and separate real video/audio sample tables passed")
  }
}
