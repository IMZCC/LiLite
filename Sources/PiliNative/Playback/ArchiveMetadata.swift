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
        Text(video.title).piliFont(.title3,weight:.bold).textSelection(.enabled)
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
  /// One quiet metadata line, as Apple's media apps do: views · bullets · date.
  private var summaryLine:some View{
    var parts:[String]=[]
    if let n=stat?.view{parts.append(short(n)+"次播放")}
    if let n=stat?.danmaku{parts.append(short(n)+"条弹幕")}
    if let t=video.pubdate,t>0{
      parts.append(Date(timeIntervalSince1970:Double(t)).formatted(.dateTime.year().month().day()))
    }
    return Text(parts.joined(separator:" · ")).monospacedDigit()
      .accessibilityLabel(parts.joined(separator:"，"))
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
