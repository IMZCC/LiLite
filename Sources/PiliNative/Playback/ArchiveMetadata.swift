import SwiftUI

struct ArchiveMetadata:View{
  let video:Video,labels:[String]
  /// Collapsed: two-line title and a chevron hint. The caller toggles on tap.
  var expanded=true
  var toggle:(()->Void)?=nil
  @State private var latest:Video.Stat?
  @State private var reload=0
  @EnvironmentObject private var accounts:AccountContext
  private var stat:Video.Stat?{latest ?? video.stat}
  var body:some View{
    VStack(alignment:.leading,spacing:8){
      if !labels.isEmpty || video.is_upower_exclusive == true || video.rights?.is_stein_gate == 1{
        ScrollView(.horizontal,showsIndicators:false){
          HStack(spacing:6){
            if video.is_upower_exclusive == true{chip("充电专属")}else if video.rights?.is_stein_gate==1{chip("互动视频")}
            ForEach(labels,id:\.self){chip($0)}
          }
        }.scrollClipDisabled()
      }
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        // The official app's proportions: the title at body size and regular weight over a
        // 13pt line of counts, not a page heading.
        Text(video.title).piliFont(.body).textSelection(.enabled)
          .lineLimit(expanded ? nil : 2)
          .fixedSize(horizontal: false, vertical: true).layoutPriority(1)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contextMenu{copyActions}
        Menu { copyActions } label: {
          Image(systemName: "ellipsis").font(.body.weight(.medium)).foregroundStyle(.secondary)
            .frame(width: 36, height: 36).contentShape(Rectangle())
        }.tint(.secondary).accessibilityLabel("视频信息")
      }
      HStack(spacing: 6) {
        summaryLine.lineLimit(1).minimumScaleFactor(0.85)
        if toggle != nil {
          Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            .rotationEffect(.degrees(expanded ? 180 : 0))
        }
      }.font(.footnote).foregroundStyle(.secondary)
    }
    .contentShape(Rectangle())
    .onTapGesture { if let toggle { TouchFeedback.light(); withAnimation(.snappy(duration: 0.3)) { toggle() } } }.onReceive(NotificationCenter.default.publisher(for:PlayerKeyMemory.changed)){n in
      if n.userInfo?["item"] as? String=="0:"+video.bvid,n.userInfo?["owner"] as? String==accounts.state.active{reload+=1}
    }.task(id:"\(video.bvid):\(accounts.state.active ?? ""):\(reload)"){
      latest=nil;guard reload>0 else{return}
      let api=BiliAPI.shared,owner=accounts.state.owner(.role(.heartbeat)) ?? "",id=video.bvid
      let fields=try? await api.sign(["bvid":id])
      guard let fields,!Task.isCancelled else{return}
      let v=try? await api.read("/x/web-interface/wbi/view",fields,expectedAccount:owner,as:Video.self)
      if !Task.isCancelled,v?.bvid==id{latest=v?.stat}
    }
  }
  private func short(_ n:Int)->String{n.formatted(.number.notation(.compactName))}
  /// One quiet metadata line, as the official app draws it: play and bullet counts each after
  /// its small icon, then the date.
  private var summaryLine:some View{
    var spoken:[String]=[]
    if let n=stat?.view{spoken.append(short(n)+"次播放")}
    if let n=stat?.danmaku{spoken.append(short(n)+"条弹幕")}
    let date=video.pubdate.flatMap{$0>0 ? Date(timeIntervalSince1970:Double($0)).formatted(.dateTime.year().month().day()) : nil}
    if let date{spoken.append(date)}
    return HStack(spacing:12){
      if let n=stat?.view{counter("play.rectangle",short(n))}
      if let n=stat?.danmaku{counter("list.bullet.rectangle",short(n))}
      if let date{Text(date)}
    }.monospacedDigit()
      .accessibilityElement(children:.ignore).accessibilityLabel(spoken.joined(separator:"，"))
  }
  private func counter(_ symbol:String,_ value:String)->some View{
    HStack(spacing:3){Image(systemName:symbol).imageScale(.small);Text(value)}
  }
  private func chip(_ text:String)->some View{
    Text(text).font(.caption.weight(.semibold)).foregroundStyle(.tint)
      .padding(.horizontal,8).padding(.vertical,3)
      .background(Color.accentColor.opacity(0.12),in:Capsule())
  }
  @ViewBuilder private var copyActions: some View {
    Button("复制标题") { UIPasteboard.general.string = video.title }
    Button("复制 BV 号") { UIPasteboard.general.string = video.bvid }
    if let aid = video.aid ?? ArchiveNumber.av(video.bvid) {
      Button("复制 AV 号") { UIPasteboard.general.string = "av" + String(aid) }
    }
  }
}
