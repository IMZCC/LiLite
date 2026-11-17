import SwiftUI

struct ArchiveTrendStrip: View {
  @ObservedObject var timeline:TimelineState
  let duration:Double
  @AppStorage("player.trend") private var enabled=false
  @State private var peaks=[Double]()
  private struct Key:Equatable{
    let active:Bool,width:Int,length:Int,revision:Int
    let source:TimelineSource?
  }
  var body:some View{
    GeometryReader{geo in
      let width=min(2048,max(2,Int(geo.size.width.rounded())))
      let use=enabled && timeline.showTrendOverlay
      Canvas{ctx,size in
        guard use,!peaks.isEmpty else{return}
        var path=Path();path.move(to:.init(x:0,y:size.height))
        for (i,h) in peaks.enumerated(){path.addLine(to:.init(x:size.width*Double(i)/Double(max(1,peaks.count-1)),y:size.height*(1-h)))}
        path.addLine(to:.init(x:size.width,y:size.height));path.closeSubpath();ctx.fill(path,with:.color(Color.accentColor.opacity(0.75)))
      }.task(id:Key(active:use,width:width,length:duration.isFinite ? Int(min(max(0,duration.rounded()),Double(Int32.max))):0,revision:timeline.trendRevision,source:timeline.source)){
        peaks=[];guard use,duration>0 else{return}
        guard let trend=timeline.trend else{timeline.requestTrend();return}
        let work=Task.detached(priority:.utility){trend.peaks(columns:width,duration:duration)}
        let computed=await withTaskCancellationHandler{await work.value}onCancel:{work.cancel()}
        if !Task.isCancelled{peaks=computed}
      }
    }.accessibilityElement(children:.ignore).accessibilityLabel("高能进度").allowsHitTesting(false)
  }
}

struct ArchiveTrendToggle:View{
  @ObservedObject var timeline:TimelineState
  @AppStorage("player.trend") private var enabled=false
  var body:some View{if enabled{Toggle("显示高能进度",isOn:$timeline.showTrendOverlay)}}
}
