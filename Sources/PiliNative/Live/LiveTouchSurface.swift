import AVKit
import SwiftUI

struct LiveTouchSurface: View {
  let player:AVPlayer, fullscreen:Bool, inspector:BulletInspector?, expand:()->Void
  @Environment(\.viewportTouch) private var touch
  @AppStorage("player.slideLevels") private var levels = true
  @AppStorage("theater.swipe") private var screen = true
  @AppStorage("theater.reverseSwipe") private var reverse = false
  @State private var axis:PlayerSlide.Axis?
  @State private var tracker: PlayerSlide.LevelTracker?
  @State private var changed = false
  @State private var hint:String?
  var body:some View {
    GeometryReader { g in
      Color.clear.contentShape(Rectangle())
        .onTapGesture(count:1,coordinateSpace:.local){ inspector?.select($0) }
        .simultaneousGesture(DragGesture(minimumDistance:16).onChanged { v in
          guard touch?.acceptsPan != false else{return}
          if axis == nil {
            axis=PlayerSlide.axis(dx:v.translation.width,dy:v.translation.height,x:v.startLocation.x,width:g.size.width,levels:levels,screen:screen)
            if axis == .brightness { tracker = .init(start: WindowMetrics.brightness, brightness: true) }
            if axis == .volume { tracker = .init(start: Double(player.presentationVolume), brightness: false) }
          }
          switch axis {
          case .brightness,.volume:
            let b=axis == .brightness
            guard let n=tracker?.level(-v.translation.height/max(1,g.size.height)) else{break}
            if b {WindowMetrics.brightness=n}else{player.presentationVolume=Float(n)}
            hint=(b ? "亮度 ":"音量 ")+"\(Int(n*100))%"
          case .fullscreen:
            if !changed, FullscreenMode.swipe(fullscreen:fullscreen,reverse:reverse,x:v.startLocation.x,width:g.size.width,dx:v.translation.width,dy:v.translation.height){
              changed=true;TouchFeedback.light();expand()
            }
          default: break
          }
        }.onEnded{ _ in axis=nil; changed=false;hint=nil;tracker=nil })
        .overlay { if let hint {Text(hint).font(.subheadline.monospacedDigit()).padding(8).foregroundStyle(.white)
          .background(.black.opacity(0.65),in:Capsule()).allowsHitTesting(false)} }
    }
  }
}
