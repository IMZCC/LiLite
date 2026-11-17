import SwiftUI

struct ArchiveChapterPanel:View{
  @ObservedObject var model:PlayerModel
  @ObservedObject private var progress:PlaybackProgress
  @ObservedObject private var timeline:TimelineState
  let bvid:String,cid:Int64
  let initial:[VideoPositions.Chapter]?
  @EnvironmentObject private var accounts:AccountContext
  @Environment(\.dismiss) private var dismiss
  @State private var rows:[VideoPositions.Chapter]?
  @State private var problem:String?
  @State private var attempt=0
  init(model:PlayerModel,bvid:String,cid:Int64,initial:[VideoPositions.Chapter]?=nil){
    self.progress=model.progress
    self.model=model;self.timeline=model.timeline;self.bvid=bvid;self.cid=cid;self.initial=initial
  }
  var body:some View{
    List{
      Toggle("进度条显示分段",isOn:$timeline.showChapterMarks)
      if let rows{
        if rows.isEmpty{Text("暂无分段").foregroundStyle(.secondary)}
        ForEach(Array(rows.enumerated()),id:\.offset){index,point in
          let end=point.end(next:index+1<rows.count ? rows[index+1].from:nil,duration:model.duration)
          let current=Double(point.from)<=model.seconds && model.seconds<(end ?? .infinity)
          Button{
            guard timeline.source?.cid==cid,timeline.source?.bvid==bvid else{return}
            model.seek(Double(point.from));dismiss()
          }label:{
            HStack{
              if let thumb=point.imgUrl.flatMap(httpsURL){
                SiteThumbnail(url:thumb){$0.resizable().scaledToFill()}placeholder:{Color.secondary.opacity(0.12)}
                  .frame(width:84,height:48).clipped().clipShape(RoundedRectangle(cornerRadius:NativeGlass.thumbRadius,style:.continuous))
              }
              VStack(alignment:.leading,spacing:4){
                Text(point.content ?? "分段 \(index+1)").lineLimit(2)
                Text(clockText(Double(point.from))+(end.map{" – "+clockText($0)} ?? "")).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
              }
              Spacer()
              if current{Image(systemName:"speaker.wave.2.fill").accessibilityLabel("正在播放")}
            }
          }.tint(current ? Color.accentColor:Color.primary)
        }
      }else if let problem{Text(problem);Button("重试"){attempt+=1}}else{ProgressView()}
    }.modifier(ReplyEdgeDismiss()).navigationTitle("视频分段").task(id:"\(bvid):\(cid):\(accounts.state.active ?? ""):\(attempt)"){
      rows=nil;problem=nil
      do{
        let values:[VideoPositions.Chapter]
        if let initial{values=initial}else{
          let owner=accounts.state.active ?? ""
          let q=try await BiliAPI.shared.sign(["bvid":bvid,"cid":String(cid)])
          let result=try await BiliAPI.shared.read("/x/player/wbi/v2",q,expectedAccount:owner,as:VideoPositions.self)
          values=result.chapters
        }
        try Task.checkCancellation();timeline.updateChapters(values,bvid:bvid,cid:cid);rows=values
      }catch{if !Task.isCancelled{problem=error.localizedDescription}}
    }
  }
}
