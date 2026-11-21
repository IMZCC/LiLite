import SwiftUI

/// The official headline (UgcHeadlineComponent, MetaLine): the title in 16 sp, a touch heavier
/// than regular (it is stroked 0.7), one line until the intro opens, with the expand arrow; then
/// the counts as 15 dp glyphs and 12 sp Ga5 text.
struct ArchiveMetadata:View{
  let video:Video,labels:[String]
  /// Collapsed: a one-line title and a chevron hint. The caller toggles on tap.
  var expanded=true
  var toggle:(()->Void)?=nil
  /// After the counts (the official line ends with "N人正在看").
  var trailing:AnyView?=nil
  @State private var latest:Video.Stat?
  @State private var reload=0
  @EnvironmentObject private var accounts:AccountContext
  private var stat:Video.Stat?{latest ?? video.stat}
  var body:some View{
    let d = OfficialIntro.d
    VStack(alignment:.leading,spacing:0){
      if !labels.isEmpty || video.is_upower_exclusive == true || video.rights?.is_stein_gate == 1{
        ScrollView(.horizontal,showsIndicators:false){
          HStack(spacing:d(6)){
            if video.is_upower_exclusive == true{chip("充电专属")}else if video.rights?.is_stein_gate==1{chip("互动视频")}
            ForEach(labels,id:\.self){chip($0)}
          }
        }.scrollClipDisabled().padding(.bottom, d(6))
      }
      HStack(alignment: .top, spacing: d(8)) {
        title.layoutPriority(1).contextMenu{copyActions}
        if toggle != nil {
          // HeadlineArrow; copying stays on a long press.
          Image(systemName: "chevron.down").font(.system(size: d(13), weight: .medium))
            .foregroundStyle(OfficialIntro.ga5)
            .rotationEffect(.degrees(expanded ? 180 : 0))
            // Centred on the first line of the title.
            .frame(width: d(20), height: oneLine > 0 ? oneLine : d(22)).accessibilityHidden(true)
        } else {
          Menu { copyActions } label: {
            Image(systemName: "ellipsis").font(.system(size: d(14), weight: .medium)).foregroundStyle(OfficialIntro.ga5)
              .frame(width: d(32), height: d(32)).contentShape(Rectangle())
          }.tint(.secondary).accessibilityLabel("视频信息")
        }
      }
      summaryLine.lineLimit(1).minimumScaleFactor(0.85)
        .font(OfficialIntro.font(12)).foregroundStyle(OfficialIntro.ga5)
        .frame(height: d(16)).padding(.top, d(7))
    }
    .contentShape(Rectangle())
    .onTapGesture { if let toggle { TouchFeedback.light(); toggle() } }.onReceive(NotificationCenter.default.publisher(for:PlayerKeyMemory.changed)){n in
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
  @State private var oneLine:CGFloat=0
  @State private var allLines:CGFloat=0
  /// The one-line title (with its "…") and the whole one cross-fade inside a height that springs
  /// between them: changing a line limit re-flowed the text in one jump, and could not be turned
  /// round mid-way.
  private var title:some View{
    let font=OfficialIntro.font(16, .medium)
    let measured=oneLine>0 && allLines>0
    return ZStack(alignment:.topLeading){
      Text(video.title).font(font).lineLimit(1)
        .onGeometryChange(for:CGFloat.self){$0.size.height} action:{oneLine=$0}
        .opacity(expanded ? 0 : 1)
      // Not selectable: selection read quick taps as a double tap (select a word), so a second
      // tap mid-way never turned the intro round. Copying is in the long-press menu.
      Text(video.title).font(font)
        .fixedSize(horizontal:false,vertical:true)
        .onGeometryChange(for:CGFloat.self){$0.size.height} action:{allLines=$0}
        .opacity(expanded ? 1 : 0)
        .allowsHitTesting(expanded)
    }
    .foregroundStyle(OfficialIntro.text1)
    .frame(maxWidth:.infinity,alignment:.leading)
    .frame(height:measured ? (expanded ? allLines : oneLine) : nil,alignment:.top)
    .clipped()
    .accessibilityElement(children:.ignore).accessibilityLabel(video.title)
    .accessibilityAddTraits(.isHeader)
  }
  private func short(_ n:Int)->String{n.formatted(.number.notation(.compactName))}
  /// One quiet metadata line, as the official app draws it: play and bullet counts each after
  /// its small icon, then the date.
  private var summaryLine:some View{
    var spoken:[String]=[]
    if let n=stat?.view{spoken.append(short(n)+"次播放")}
    if let n=stat?.danmaku{spoken.append(short(n)+"条弹幕")}
    // Date and time of publishing, as the original's line ("2026年11月20日 11:18").
    let date=video.pubdate.flatMap{$0>0 ? Date(timeIntervalSince1970:Double($0)).formatted(.dateTime.year().month().day().hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)) : nil}
    if let date{spoken.append(date)}
    return HStack(spacing:OfficialIntro.d(10)){
      if let n=stat?.view{counter("play.rectangle",short(n))}
      if let n=stat?.danmaku{counter("list.bullet.rectangle",short(n))}
      if let date{Text(date)}
      if let trailing{trailing}
    }.monospacedDigit()
      .accessibilityElement(children:.combine).accessibilityLabel(spoken.joined(separator:"，"))
  }
  /// UgcMetaText: a 15 dp glyph, 3 dp, the number.
  private func counter(_ symbol:String,_ value:String)->some View{
    HStack(spacing:OfficialIntro.d(3)){
      Image(systemName:symbol).font(.system(size:OfficialIntro.d(11.5))).frame(width:OfficialIntro.d(15),height:OfficialIntro.d(15))
      Text(value)
    }
  }
  private func chip(_ text:String)->some View{
    Text(text).font(OfficialIntro.font(10, .semibold)).foregroundStyle(.tint)
      .padding(.horizontal,OfficialIntro.d(6)).frame(height:OfficialIntro.d(16))
      .background(Color.accentColor.opacity(0.12),in:RoundedRectangle(cornerRadius:OfficialIntro.d(3),style:.continuous))
  }
  @ViewBuilder private var copyActions: some View {
    Button("复制标题") { UIPasteboard.general.string = video.title }
    Button("复制 BV 号") { UIPasteboard.general.string = video.bvid }
    if let aid = video.aid ?? ArchiveNumber.av(video.bvid) {
      Button("复制 AV 号") { UIPasteboard.general.string = "av" + String(aid) }
    }
  }
}
