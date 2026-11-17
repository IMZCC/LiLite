import SwiftUI

/// One or two coins drop into the tray before the explicit confirmation is handed back.
struct ArchiveCoinStage:View {
  let amount:Int,started:Date?,reduce:Bool,choose:(Int)->Void,pay:()->Void
  var body:some View{
    TimelineView(.animation(paused:started == nil || reduce)){frame in
      let t=started.map{min(1,max(0,frame.date.timeIntervalSince($0)/0.40))} ?? 0
      let drop=min(1,max(0,(t-0.20)/0.8))
      ZStack{
        Image(systemName:"tray.fill").font(.system(size:48)).foregroundStyle(.tint)
          .offset(y:28+CGFloat(t>0.86 ? 3*sin((t-0.86)*Double.pi/0.14):0))
        ForEach(0..<max(1,min(2,amount)),id:\.self){index in
          let delay=Double(index)*0.13
          let p=min(1,max(0,(drop-delay)/(1-delay)))
          ZStack {
            Circle().fill(.yellow.gradient)
            Circle().strokeBorder(.orange,lineWidth:1.5).padding(2)
            Text("币").font(.caption.bold()).foregroundStyle(.brown)
          }.frame(width:28,height:28)
            .rotation3DEffect(.degrees(260*p),axis:(x:0,y:1,z:0))
            .scaleEffect(1-0.35*p).opacity(p>0.92 ? max(0,(1-p)/0.08):1)
            .offset(x:amount==2 ? CGFloat(index==0 ? -11:11):0,y:-18+CGFloat(47*p*p))
        }
      }.frame(maxWidth:.infinity,minHeight:86)
    }.contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance:22).onEnded{v in
        guard started==nil else{return}
        let x=v.translation.width,y=v.translation.height
        if abs(x)>abs(y){choose(x<0 ? 2:1)}else if y < -24{pay()}
      })
      .accessibilityHidden(true)
  }
}
